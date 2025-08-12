require_relative '../models/player'
require_relative '../models/match'

class QueueService
  MAX_QUEUE_SIZE = 8
  READY_CHECK_TIMEOUT = 60 # seconds
  
  def self.instance
    @instance ||= new
  end
  
  def initialize
    @queue = []
    @ready_players = []
    @ready_check_active = false
    @match_in_progress = false
  end
  
  def add_player(discord_user)
    player = Player.find_or_create_by_discord(discord_user)
    
    return { success: false, message: 'You are already in the queue!' } if player_in_queue?(player)
    return { success: false, message: 'Queue is full!' } if queue_full?
    return { success: false, message: 'Match is in progress!' } if @match_in_progress
    
    player.update(last_seen: Time.now)
    
    # Add to queue
    @queue << {
      player: player,
      discord_user: discord_user,
      joined_at: Time.now
    }
    
    # Update database queue status
    QueuePlayer.find_or_create(player_id: player.id) do |qp|
      qp.status = 'queued'
      qp.joined_at = Time.now
      qp.preferred_region = player.region
    end
    
    if @queue.size >= MAX_QUEUE_SIZE
      start_ready_check
    end
    
    { 
      success: true, 
      message: "Added to queue (#{@queue.size}/#{MAX_QUEUE_SIZE})",
      queue_status: queue_status
    }
  end
  
  def remove_player(discord_user)
    player = Player.find(discord_id: discord_user.id.to_s)
    return { success: false, message: 'You are not in the queue!' } unless player
    
    @queue.reject! { |q| q[:player].id == player.id }
    @ready_players.reject! { |r| r[:player].id == player.id }
    
    # Remove from database
    QueuePlayer.where(player_id: player.id).delete
    
    { 
      success: true, 
      message: "Removed from queue",
      queue_status: queue_status
    }
  end
  
  def player_ready(discord_user)
    return { success: false, message: 'No ready check active!' } unless @ready_check_active
    
    player = Player.find(discord_id: discord_user.id.to_s)
    return { success: false, message: 'You are not in the queue!' } unless player
    
    queue_entry = @queue.find { |q| q[:player].id == player.id }
    return { success: false, message: 'You are not in the current queue!' } unless queue_entry
    
    # Add to ready players if not already there
    unless @ready_players.any? { |r| r[:player].id == player.id }
      @ready_players << {
        player: player,
        discord_user: discord_user,
        ready_at: Time.now
      }
      
      # Update database status
      QueuePlayer.where(player_id: player.id).update(
        status: 'ready',
        ready_at: Time.now
      )
    end
    
    if @ready_players.size >= MAX_QUEUE_SIZE
      create_match
    end
    
    { 
      success: true, 
      message: "You are ready! (#{@ready_players.size}/#{MAX_QUEUE_SIZE})",
      ready_status: ready_status
    }
  end
  
  def queue_status
    {
      size: @queue.size,
      max_size: MAX_QUEUE_SIZE,
      players: @queue.map do |entry|
        {
          username: entry[:player].username,
          display_name: entry[:player].display_name,
          region: entry[:player].region || 'Unknown',
          joined_at: entry[:joined_at].strftime('%H:%M'),
          time_waiting: time_waiting(entry[:joined_at])
        }
      end,
      ready_check_active: @ready_check_active,
      match_in_progress: @match_in_progress
    }
  end
  
  def ready_status
    return nil unless @ready_check_active
    
    {
      ready_count: @ready_players.size,
      required: MAX_QUEUE_SIZE,
      players_ready: @ready_players.map { |r| r[:player].username },
      players_waiting: @queue.reject { |q| @ready_players.any? { |r| r[:player].id == q[:player].id } }
                            .map { |q| q[:player].username }
    }
  end
  
  private
  
  def player_in_queue?(player)
    @queue.any? { |entry| entry[:player].id == player.id }
  end
  
  def queue_full?
    @queue.size >= MAX_QUEUE_SIZE
  end
  
  def start_ready_check
    @ready_check_active = true
    @ready_players.clear
    
    # Set timeout to cancel ready check
    Thread.new do
      sleep(READY_CHECK_TIMEOUT)
      cancel_ready_check if @ready_check_active
    end
  end
  
  def cancel_ready_check
    @ready_check_active = false
    @ready_players.clear
    
    # Reset queue player statuses
    @queue.each do |entry|
      QueuePlayer.where(player_id: entry[:player].id).update(status: 'queued')
    end
  end
  
  def create_match
    @ready_check_active = false
    @match_in_progress = true
    
    # Get ready players
    match_players = @ready_players.dup
    
    # Clear queue and ready players
    @queue.clear
    @ready_players.clear
    
    # Update database - remove from queue, set as playing
    match_players.each do |entry|
      QueuePlayer.where(player_id: entry[:player].id).update(status: 'playing')
    end
    
    # Return match data for server creation
    {
      players: match_players,
      region: determine_best_region(match_players)
    }
  end
  
  def determine_best_region(players)
    regions = players.map { |p| p[:player].region }.compact
    return 'Sydney' if regions.empty?
    
    # Count regions and pick most common, default to Sydney for Australia
    region_counts = regions.group_by(&:itself).transform_values(&:count)
    most_common = region_counts.max_by { |_, count| count }&.first
    
    most_common || 'Sydney'
  end
  
  def time_waiting(joined_at)
    seconds = (Time.now - joined_at).to_i
    if seconds < 60
      "#{seconds}s"
    else
      "#{seconds / 60}m #{seconds % 60}s"
    end
  end
end