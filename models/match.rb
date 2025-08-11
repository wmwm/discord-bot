require_relative '../config/database'

class Match < Sequel::Model
  plugin :timestamps, update_on_create: true
  
  one_to_many :match_players
  many_to_many :players, through: :match_players
  many_to_one :server
  
  def self.create_new_match(server_id, map_name, region = 'Sydney')
    create(
      server_id: server_id,
      map_name: map_name,
      region: region,
      status: 'active',
      started_at: Time.now
    )
  end
  
  def add_players(players_array)
    players_array.each_with_index do |player, index|
      team = index < 4 ? 'red' : 'blue'  # First 4 to red, rest to blue
      
      add_match_player(
        player_id: player.id,
        team: team,
        joined_at: Time.now
      )
    end
  end
  
  def red_team
    players.join(:match_players, player_id: :id)
           .where(match_players__team: 'red')
  end
  
  def blue_team
    players.join(:match_players, player_id: :id)
           .where(match_players__team: 'blue')
  end
  
  def complete_match!
    self.status = 'completed'
    self.ended_at = Time.now
    self.duration_minutes = ((ended_at - started_at) / 60).round
    save_changes
    
    # Update player statistics
    players.each(&:update_stats!)
  end
  
  def cancel_match!
    self.status = 'cancelled'
    self.ended_at = Time.now
    save_changes
  end
  
  def match_summary
    {
      id: id,
      server_id: server_id,
      map: map_name,
      region: region,
      status: status,
      duration: duration_minutes || 0,
      started_at: started_at&.strftime('%Y-%m-%d %H:%M UTC'),
      red_team: red_team.map(&:username),
      blue_team: blue_team.map(&:username),
      logs_url: logs_url
    }
  end
end