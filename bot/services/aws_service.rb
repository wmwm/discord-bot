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
    
    # Read user_data script content
    user_data_script = File.read('aws/user_data.sh')
    
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
  
  end