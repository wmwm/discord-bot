require 'aws-sdk-ec2'
require_relative '../models/server'

class AwsService
  def initialize
    @ec2 = Aws::EC2::Client.new(region: 'ap-southeast-2')
    @resource = Aws::EC2::Resource.new(client: @ec2)
  end
  
  def deploy_server(region = 'Sydney', map_name = 'dm4')
    # Terminate any existing servers first
    terminate_all_servers
    
    user_data = generate_user_data(map_name)
    
    instance = @resource.create_instances({
      image_id: 'ami-0d02292614a3b0df1', # Ubuntu 22.04 LTS
      min_count: 1,
      max_count: 1,
      instance_type: 't2.micro',
      key_name: 'fortress-one-key',
      security_group_ids: ['sg-05ce110e128b8509c'], # Replace with actual security group
      user_data: Base64.encode64(user_data),
      tag_specifications: [{
        resource_type: 'instance',
        tags: [
          { key: 'Name', value: "FortressOne-#{Time.now.to_i}" },
          { key: 'Project', value: 'PUGBot' },
          { key: 'Region', value: region }
        ]
      }]
    }).first
    
    # Create server record
    server = Server.create(
      aws_instance_id: instance.id,
      region: region,
      status: 'launching',
      launched_at: Time.now
    )
    
    # Wait for instance to get public IP
    Thread.new do
      wait_for_server_ready(instance, server)
    end
    
    {
      success: true,
      instance_id: instance.id,
      server_id: server.id,
      region: region,
      map: map_name,
      status: 'launching'
    }
  rescue => e
    {
      success: false,
      error: e.message
    }
  end
  
  def get_server_status(server_id)
    server = Server[server_id]
    return { success: false, error: 'Server not found' } unless server
    
    begin
      instance = @resource.instance(server.aws_instance_id)
      instance.load
      
      # Update server status
      server.update(
        status: instance.state.name,
        public_ip: instance.public_ip_address
      )
      
      {
        success: true,
        server_id: server_id,
        aws_instance_id: server.aws_instance_id,
        status: instance.state.name,
        public_ip: instance.public_ip_address,
        region: server.region,
        uptime: server.uptime,
        player_count: server.player_count
      }
    rescue => e
      { success: false, error: e.message }
    end
  end
  
  def terminate_server(server_id)
    server = Server[server_id]
    return { success: false, error: 'Server not found' } unless server
    
    begin
      instance = @resource.instance(server.aws_instance_id)
      instance.terminate
      
      server.update(status: 'terminating')
      
      { success: true, message: 'Server termination initiated' }
    rescue => e
      { success: false, error: e.message }
    end
  end
  
  def terminate_all_servers
    # Find all FortressOne instances
    instances = @ec2.describe_instances({
      filters: [
        { name: 'tag:Project', values: ['PUGBot'] },
        { name: 'instance-state-name', values: ['running', 'pending'] }
      ]
    })
    
    instance_ids = []
    instances.reservations.each do |reservation|
      reservation.instances.each do |instance|
        instance_ids << instance.instance_id
      end
    end
    
    unless instance_ids.empty?
      @ec2.terminate_instances(instance_ids: instance_ids)
      
      # Update database records
      Server.where(aws_instance_id: instance_ids).update(status: 'terminating')
    end
    
    { terminated_count: instance_ids.size, instance_ids: instance_ids }
  end
  
  def list_active_servers
    servers = Server.where(status: ['launching', 'running']).all
    
    servers.map do |server|
      status_info = get_server_status(server.id)
      status_info[:success] ? status_info : nil
    end.compact
  end
  
  private
  
  def generate_user_data(map_name)
    <<~SCRIPT
      #!/bin/bash
      exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
      
      # Update system
      apt-get update
      
      # Install Docker
      apt-get install -y docker.io
      systemctl start docker
      systemctl enable docker
      
      # Install screen for process management
      apt-get install -y screen
      
      # Create FortressOne directory
      mkdir -p /opt/fortressone
      cd /opt/fortressone
      
      # Download FortressOne
      wget -O fortress-one.tar.gz https://github.com/FortressOne/server-qwprogs/releases/download/v1.0.4/fortress-one-linux-x64.tar.gz
      tar -xzf fortress-one.tar.gz
      chmod +x mvdsv
      
      # Download maps
      mkdir -p fortress/maps
      cd fortress/maps
      wget https://maps.quakeworld.nu/maps/#{map_name}.bsp.zip
      unzip #{map_name}.bsp.zip
      
      # Create server config
      cd /opt/fortressone
      cat > server.cfg << 'EOF'
      hostname "PUG Server - #{map_name}"
      maxclients 16
      map #{map_name}
      port 27500
      EOF
      
      # Start server in screen session
      screen -dmS fortressone ./mvdsv +exec server.cfg
      
      # Create simple HTTP status server
      python3 -c "
      import http.server
      import socketserver
      import json
      import subprocess
      import time
      
      class StatusHandler(http.server.SimpleHTTPRequestHandler):
          def do_GET(self):
              if self.path == '/status':
                  try:
                      result = subprocess.run(['screen', '-list'], capture_output=True, text=True)
                      server_running = 'fortressone' in result.stdout
                      
                      status = {
                          'server_running': server_running,
                          'map': '#{map_name}',
                          'port': 27500,
                          'uptime': int(time.time() - #{Time.now.to_i}),
                          'timestamp': time.time()
                      }
                      
                      self.send_response(200)
                      self.send_header('Content-type', 'application/json')
                      self.end_headers()
                      self.wfile.write(json.dumps(status).encode())
                  except Exception as e:
                      self.send_response(500)
                      self.send_header('Content-type', 'application/json')
                      self.end_headers()
                      self.wfile.write(json.dumps({'error': str(e)}).encode())
              else:
                  super().do_GET()
      
      with socketserver.TCPServer(('', 28000), StatusHandler) as httpd:
          httpd.serve_forever()
      " &
    SCRIPT
  end
  
  def wait_for_server_ready(instance, server)
    60.times do |i|
      sleep(5)
      
      begin
        instance.reload
        if instance.public_ip_address
          server.update(
            public_ip: instance.public_ip_address,
            status: instance.state.name
          )
          break
        end
      rescue
        # Continue waiting
      end
    end
  end
end