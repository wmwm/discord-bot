#!/usr/bin/env ruby

require 'rexml/document'
require 'discordrb'
require 'dotenv/load'
require 'logger'

# Load models and services
require_relative 'config/database'
require_relative 'models/player'
require_relative 'models/match'
require_relative 'services/queue_service'
require_relative 'services/aws_service'
require_relative 'services/ai_service'

class PugBot
  def initialize
    @bot = Discordrb::Commands::CommandBot.new(
      token: ENV['DISCORD_PUG_BOT_TOKEN'],
      client_id: ENV['DISCORD_PUG_CLIENT_ID'],
      prefix: '!',
      advanced_functionality: true
    )
    
    @logger = Logger.new($stdout)
    @logger.level = Logger::INFO
    
    @queue_service = QueueService.instance
    @aws_service = AwsService.new
    @ai_service = AiService.new
    
    setup_commands
    setup_events
  end
  
  def setup_commands
    # Queue management commands
    @bot.command(:join) do |event|
      result = @queue_service.add_player(event.user)
      
      if result[:success]
        event << "✅ #{result[:message]}"
        
        # Send queue status
        status = @queue_service.queue_status
        if status[:size] > 0
          queue_list = status[:players].map.with_index(1) do |p, i|
            "#{i}. #{p[:display_name]} (#{p[:region]}) - #{p[:time_waiting]}"
          end.join("\n")
          
          event << "📋 **Current Queue (#{status[:size]}/#{status[:max_size]}):**\n#{queue_list}"
        end
        
        # Check if ready check should start
        if status[:size] >= 8
          event << "🚨 **Queue is full! Starting ready check...**"
          event << "Type `!ready` within 60 seconds to confirm you're ready to play!"
          
          # Mention all queued players
          mentions = status[:players].map { |p| "<@#{p[:discord_id]}>" }.join(' ')
          event << "#{mentions} - Ready check active!"
        end
      else
        event << "❌ #{result[:message]}"
      end
    end
    
    @bot.command(:leave) do |event|
      result = @queue_service.remove_player(event.user)
      event << result[:success] ? "✅ #{result[:message]}" : "❌ #{result[:message]}"
    end
    
    @bot.command(:ready) do |event|
      result = @queue_service.player_ready(event.user)
      
      if result[:success]
        event << "✅ #{result[:message]}"
        
        # Check if match should start
        ready_status = @queue_service.ready_status
        if ready_status && ready_status[:ready_count] >= 8
          event << "🎮 **All players ready! Creating match...**"
          start_match(event)
        elsif ready_status
          remaining = 8 - ready_status[:ready_count]
          event << "⏳ Waiting for #{remaining} more players to ready up..."
        end
      else
        event << "❌ #{result[:message]}"
      end
    end
    
    @bot.command(:status) do |event|
      status = @queue_service.queue_status
      
      if status[:size] == 0
        event << "📋 **Queue is empty.** Type `!join` to start a game!"
      else
        queue_list = status[:players].map.with_index(1) do |p, i|
          "#{i}. #{p[:display_name]} (#{p[:region]}) - #{p[:time_waiting]}"
        end.join("\n")
        
        embed = Discordrb::Webhooks::Embed.new(
          title: "🎯 PUG Queue Status",
          description: "**Current Queue (#{status[:size]}/#{status[:max_size]}):**\n#{queue_list}",
          color: status[:size] >= 8 ? 0x00ff00 : 0xffa500,
          timestamp: Time.now
        )
        
        if status[:ready_check_active]
          ready_status = @queue_service.ready_status
          embed.add_field(
            name: "🚨 Ready Check Active",
            value: "Ready: #{ready_status[:ready_count]}/8\nWaiting: #{ready_status[:players_waiting].join(', ')}",
            inline: false
          )
        end
        
        event.channel.send_embed('', embed)
      end
    end
    
    # Server management commands  
    @bot.command(:startserver) do |event, map_name = 'dm4'|
      event << "🚀 **Starting FortressOne server...**"
      event << "Map: #{map_name}"
      event << "Region: Sydney (AU)"
      
      result = @aws_service.deploy_server('Sydney', map_name)
      
      if result[:success]
        event << "✅ **Server deployment initiated!**"
        event << "Instance ID: #{result[:instance_id]}"
        event << "Status: #{result[:status]}"
        event << "⏳ Server will be ready in ~2-3 minutes..."
      else
        event << "❌ **Failed to start server:** #{result[:error]}"
      end
    end
    
    @bot.command(:servers) do |event|
      servers = @aws_service.list_active_servers
      
      if servers.empty?
        event << "📋 **No active servers.**"
      else
        server_list = servers.map do |server|
          "🖥️ **#{server[:region]} Server**\n" +
          "IP: #{server[:public_ip]}:27500\n" +
          "Status: #{server[:status]}\n" +
          "Uptime: #{server[:uptime]}\n" +
          "Players: #{server[:player_count]}"
        end.join("\n\n")
        
        event << "🌐 **Active Servers:**\n#{server_list}"
      end
    end
    
    # Player statistics
    @bot.command(:profile) do |event, mentioned_user = nil|
      target_user = mentioned_user ? event.message.mentions.first : event.user
      player = Player.find(discord_id: target_user.id.to_s)
      
      unless player
        event << "❌ **Player not found.** Play some matches first!"
        return
      end
      
      profile = player.profile_summary
      
      embed = Discordrb::Webhooks::Embed.new(
        title: "👤 Player Profile: #{profile[:display_name]}",
        color: 0x0099ff,
        thumbnail: Discordrb::Webhooks::EmbedThumbnail.new(url: target_user.avatar_url),
        timestamp: Time.now
      )
      
      embed.add_field(name: "🌍 Region", value: profile[:region], inline: true)
      embed.add_field(name: "🎮 Total Matches", value: profile[:total_matches], inline: true)
      embed.add_field(name: "🏆 Win Rate", value: profile[:win_rate], inline: true)
      embed.add_field(name: "⚔️ Average Frags", value: profile[:avg_frags], inline: true)
      embed.add_field(name: "👀 Last Seen", value: profile[:last_seen] || 'Never', inline: true)
      
      event.channel.send_embed('', embed)
    end
    
    # AI-powered commands
    @bot.command(:analyze) do |event, *args|
      query = args.join(' ')
      return event << "❌ **Please provide a query to analyze.**" if query.empty?
      
      event << "🤖 **Analyzing:** #{query}"
      
      begin
        response = @ai_service.analyze_query(query, event.user)
        event << "📊 **Analysis:**\n#{response}"
      rescue => e
        event << "❌ **AI analysis failed:** #{e.message}"
      end
    end
    
    # Admin commands
    @bot.command(:reset, required_roles: ['Admin', 'Moderator']) do |event|
      @queue_service.reset_queue
      event << "✅ **Queue has been reset by admin.**"
    end
    
    @bot.command(:forcestart, required_roles: ['Admin', 'Moderator']) do |event|
      if @queue_service.queue_status[:size] < 4
        event << "❌ **Need at least 4 players to force start a match.**"
        return
      end
      
      event << "⚡ **Admin force starting match...**"
      start_match(event, force: true)
    end
  end
  
  def setup_events
    @bot.ready do |event|
      @logger.info "PUG Bot Ready! Logged in as #{@bot.profile.username}##{@bot.profile.discriminator}"
      @logger.info "Bot is running in #{@bot.servers.count} servers"
      
      @bot.servers.each do |id, server|
        @logger.info "Connected to server: #{server.name} (ID: #{id})"
        
        # Find #pugbot channel
        pugbot_channel = server.channels.find { |c| c.name == 'pugbot' }
        if pugbot_channel
          @logger.info "Found #pugbot channel in #{server.name}"
          pugbot_channel.send_message("🤖 **PUG Bot is online and ready!**\nType `!join` to start playing!")
        end
      end
      
      # Set bot activity
      @bot.game = "Type !join to play | #{@queue_service.queue_status[:size]}/8 in queue"
    end
    
    @bot.member_join do |event|
      @logger.info "New member joined: #{event.user.username}"
      
      # Create player record
      Player.find_or_create_by_discord(event.user)
      
      # Send welcome message in general channel
      general = event.server.general_channel
      general&.send_message("👋 Welcome #{event.user.mention}! Head to #pugbot and type `!join` to start playing!")
    end
    
    # Update bot activity every 30 seconds
    Thread.new do
      loop do
        sleep(30)
        begin
          queue_size = @queue_service.queue_status[:size]
          @bot.game = "Type !join to play | #{queue_size}/8 in queue"
        rescue => e
          @logger.error "Failed to update bot activity: #{e.message}"
        end
      end
    end
  end
  
  def start_match(event, force: false)
    begin
      # Get match data from queue
      match_data = force ? @queue_service.force_create_match : @queue_service.get_ready_match
      
      return event << "❌ **No match ready to start.**" unless match_data
      
      # Start server
      server_result = @aws_service.deploy_server(match_data[:region], 'dm4')
      
      unless server_result[:success]
        event << "❌ **Failed to start server:** #{server_result[:error]}"
        return
      end
      
      # Create match record
      match = Match.create_new_match(
        server_result[:instance_id],
        'dm4',
        match_data[:region]
      )
      
      match.add_players(match_data[:players].map { |p| p[:player] })
      
      # Announce match
      embed = Discordrb::Webhooks::Embed.new(
        title: "🎮 Match Started!",
        description: "Server is starting up...",
        color: 0x00ff00,
        timestamp: Time.now
      )
      
      red_team = match.red_team.map(&:username).join(', ')
      blue_team = match.blue_team.map(&:username).join(', ')
      
      embed.add_field(name: "🔴 Red Team", value: red_team, inline: false)
      embed.add_field(name: "🔵 Blue Team", value: blue_team, inline: false)
      embed.add_field(name: "🗺️ Map", value: 'dm4', inline: true)
      embed.add_field(name: "🌍 Region", value: match_data[:region], inline: true)
      embed.add_field(name: "⏳ Status", value: "Server starting...", inline: true)
      
      event.channel.send_embed('', embed)
      
      # Mention all players
      mentions = match_data[:players].map { |p| "<@#{p[:discord_user].id}>" }.join(' ')
      event << "#{mentions} - Your match is starting! Server details will be posted shortly."
      
    rescue => e
      @logger.error "Failed to start match: #{e.message}"
      event << "❌ **Failed to start match:** #{e.message}"
    end
  end
  
  def run
    @bot.run
  end
end

# Start the bot
if __FILE__ == $0
  bot = PugBot.new
  bot.run
end