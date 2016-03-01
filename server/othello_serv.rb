#!/Users/nakaso/.rbenv/shims/ruby

# -------------------------------------------------
# library/module
# -------------------------------------------------
require 'em-websocket'
require 'optparse'
require 'json'

# -------------------------------------------------
# How to Use
# -------------------------------------------------
# execute:
#   ruby othello_serv.rb
#
# require:
#   gem install em-websocket


# -------------------------------------------------
# Structure
# -------------------------------------------------
# [Server]
#
# [Match]
#
# [Player]
#
# [Game]
#
# [Board]
#
# [Stone]
#


# -------------------------------------------------
# Const
# -------------------------------------------------
DEFAULT_PORT = 8088
# action type
#   role:     role送信指示[:player/:monitor]
#   wait:     次回指示待ち指示
#   attack:   石配置指示
#   deffence: 石配置待ち指示
#   finish:   対戦終了通知
#   monitor:  観戦者向け通信
PLAYER_ACTION = [:role, :wait, :attack, :deffence, :finish, :monitor]


# -------------------------------------------------
# Server
# -------------------------------------------------
class Server
  def initialize(port)
    $log.info "started on ws://localhost:#{port}"
    Match.new

    EM::WebSocket.start({:host => 'localhost', :port => port}) do |session|

      # session確立時
      session.onopen do
        Player.new(session)
      end

      # session切断時
      session.onclose do
        # TODO: そのうち対応
      end
    
      # error検知時
      session.onerror do
        # TODO: そのうち対応
      end
    
      # message受信時
      session.onmessage do |msg|
        $log.info "===================================="
        $log.info "<<<< #{Player.who(session).id}: #{msg}"
        begin
          msg = JSON.load(msg)
        rescue
          $log.error("message is not JSON")
          raise ArgumentError
        end

        if match = Match.which(Player.who(session))
          match.recv(Player.who(session), msg)
        else
          Match.matching(Player.who(session), msg)
        end
      end
      
    end
  end
end


# -------------------------------------------------
# MatchClass
# -------------------------------------------------
class Match
  @@list = []
  attr_accessor :p1, :p2, :monitor, :game

  #
  #
  def initialize
    @@list << self
  end

  #
  #
  def self.matching(plyr, msg)
    case msg['role']
    when 'player'
      if @@list[-1].p1 == nil
        @@list[-1].p1 = plyr
        @@list[-1].p1.name = msg['name']
        plyr.operation :wait
      else
        @@list[-1].p2 = plyr
        @@list[-1].p2.name = msg['name']
        @@list[-1].start
        self.new()
      end

    when 'monitor'
      @@list[-1].monitor = plyr
      plyr.operation :wait

    else
      $log.error("role:#{msg['role']} is not acceptable")
      raise ArgumentError

    end
  end

  #
  # 所属matchの検索
  def self.which(plyr)
    return @@list.find{|m| m.p1 == plyr or m.p2 == plyr}
  end

  #
  # 対戦開始
  def start
    $log.info "GameMatching: #{self.p1.id} vs #{self.p2.id}"
    # 先行をRandomで決定
    pre = [*1..2].sample
    post = pre == 1 ? 2 : 1
    # Gameの生成, 関連付け
    self.game = Game.new
    # Player情報の更新
    eval("self.p#{pre}.is_attacker = true")
    eval("self.p#{pre}.clr = :b")
    eval("self.p#{post}.is_attacker = false")
    eval("self.p#{post}.clr = :w")
    # actionの通知
    eval("self.p#{post}.operation :deffence, self.game.board")
    eval("self.p#{pre}.operation :attack, self.game.board")
    if @monitor
      @monitor.clr  = "#{self.p1.name}'s color: #{self.p1.clr}"
      @monitor.clr += " / #{self.p2.name}'s color: #{self.p2.clr}"
      @monitor.operation(:monitor, @game.board.to_a)
    end
  end

  #
  # コマを置かれた場合に起動
  #   - attackerからの信号でなければ無視
  #   - コマ配置
  #   - 次のアクション指示[:change, :pass, :finish]
  def recv(plyr, msg)
    #
    unless plyr.is_attacker
      plyr.operation :deffence, @game.board
      return
    end
    #
    action = @game.put(plyr.clr, msg['x'], msg['y'])
    #
    eval "#{action}"
  end

  #
  #
  def change
    if @p1.is_attacker
      @p1.is_attacker = false
      @p2.is_attacker = true
    else
      @p1.is_attacker = true
      @p2.is_attacker = false
    end
    deffender.operation(:deffence, @game.board.to_a)
    attacker.operation(:attack, @game.board.to_a)
    @monitor.operation(:monitor, @game.board.to_a) if @monitor
  end

  #
  #
  def pass
    deffender.operation(:deffence, @game.board.to_a)
    attacker.operation(:attack, @game.board.to_a)
    @monitor.operation(:monitor, @game.board.to_a) if @monitor
  end

  #
  # 対戦終了
  #   - 全て終了のパターン
  #   - 途中終了のパターン(途中終了の場合、攻撃者のルール違反)
  def finish
    if @game.board.filled?
      # 結果判定
      $log.debug @game.board.count(attacker.clr)
      case @game.board.count(attacker.clr)
      when 0..31
        attacker.operation(:finish, @game.board.to_a, :lose)
        deffender.operation(:finish, @game.board.to_a, :win)
        if @monitor
          @monitor.operation(:finish, @game.board.to_a, "winner is #{deffender.name}")
        end

      when 32
        attacker.operation(:finish, @game.board.to_a, :draw)
        deffender.operation(:finish, @game.board.to_a, :draw)
        if @monitor
          @monitor.operation(:finish, @game.board.to_a, :draw)
        end

      when 33..64
        attacker.operation(:finish, @game.board.to_a, :win)
        deffender.operation(:finish, @game.board.to_a, :lose)
        if @monitor
          @monitor.operation(:finish, @game.board.to_a, "winner is #{attacker.name}")
        end

      end

    else
      attacker.operation(:finish, @game.board.to_a, :lose)
      deffender.operation(:finish, @game.board.to_a, :win)
      if @monitor
        @monitor.operation(:finish, @game.board.to_a, "winner is #{deffender.name}")
      end

    end
  end

  #
  #
  def attacker
    return attacker = @p1.is_attacker ? @p1 : @p2
  end

  #
  #
  def deffender
    return deffender = @p1.is_attacker ? @p2 : @p1
  end

end


# -------------------------------------------------
# PlayerClass
# -------------------------------------------------
class Player
  @@entry = {}
  attr_accessor :session, :name, :clr, :is_attacker

  #
  #
  def initialize(session)
    @session = session
    @@entry[session] = self

    operation(:role)
  end

  #
  def operation(act, brd=nil, rslt=nil)
    $log.info ">>>> #{Player.who(@session).id}: #{act}"
    raise NameError unless PLAYER_ACTION.include? act
    @session.send({action: act, board: brd.to_a, result: rslt, color: @clr}.to_json)
  end

  #
  # sessionからPlayerインスタンスを引いて返却
  def self.who(session); @@entry[session]; end

  #
  #
  def is_attacker?; @is_attacker; end

  #
  # PlayerID
  #   object_idそのままだと長いので下6桁に
  def id; self.object_id.to_s[-6..-1]; end

end


# -------------------------------------------------
# GameClass
# -------------------------------------------------
class Game
  attr_accessor :board
  
	#
	# ボードの生成と初期石配置
  def initialize
    @board = Board.new
    @board.placing(3,3,Stone.new(:w))
    @board.placing(4,4,Stone.new(:w))
    @board.placing(3,4,Stone.new(:b))
    @board.placing(4,3,Stone.new(:b))
  end

  #
  # 石配置
  #   - 石を配置可能か
  #   - 石の配置 & ひっくり返す
  #   - 攻守を入れ替えるか判定(強制パスじゃないか)
  def put(clr, x, y)
    #
    where = where_reversible(x,y,clr)
    return :finish if where == []
    $log.debug("#{x},#{y} is reversible")
    #
    @board.placing(x,y,Stone.new(clr))
    reverse(x,y,where)
    @board.screen
    #
    return next_action(Stone.new(clr).other)
  end

  #
  # コマを配置可能か確認
  #   - 空いてるか
  #   - ひっくり返せるか
  def where_reversible(x, y, clr)
    #
    return [] if @board.stone(x,y)
    $log.debug("#{x},#{y} is empty")
    #
    where = []
    where << {x: -1, y:  1} if reversible?(x,y,clr,-1, 1)
    where << {x: -1, y:  0} if reversible?(x,y,clr,-1, 0)
    where << {x: -1, y: -1} if reversible?(x,y,clr,-1,-1)
    where << {x:  0, y:  1} if reversible?(x,y,clr, 0, 1)
    where << {x:  0, y: -1} if reversible?(x,y,clr, 0,-1)
    where << {x:  1, y:  1} if reversible?(x,y,clr, 1, 1)
    where << {x:  1, y:  0} if reversible?(x,y,clr, 1, 0)
    where << {x:  1, y: -1} if reversible?(x,y,clr, 1,-1)
    where
  end

  #
  # 指定された方向でひっくり返すことができるか確認
  # 指定方向に石を確認し、異色が出てその先に同色が出たらOK
  #   h .. 水平方向
  #   v .. 垂直方向
  def reversible?(x, y, clr, h, v)
    $log.debug "x:#{x},y:#{y},clr:#{clr},h:#{h},v:#{v}"
    target = []
    x+=h; y+=v
    until x<0 or x>7 or y<0 or y>7 # 盤外に出たら終了
      $log.debug("  looping x:#{x}, y:#{y}")
      break unless @board.stone(x,y)
      if target.uniq.size <= 2 # 近い2色分押さえとけばOK
        target << @board.stone(x,y).clr
      else
        break
      end
      x+=h; y+=v # 対象の移動
    end
    $log.debug "target.uniq == #{target.uniq}"
    $log.debug "[Stone.new] == #{[Stone.new(clr).other.clr, clr]}"
    $log.debug "#{target.uniq == [Stone.new(clr).other.clr, clr]}"
    return target.uniq == [Stone.new(clr).other.clr, clr]
  end

  #
  #
  def reverse(x, y, where)
    where.each do | w |
      until @board.stone(x, y).eql? @board.stone(x+w[:x], y+w[:y])
        @board.stone(x+w[:x], y+w[:y]).reverse
        w[:x] += w[:x]<=>0
        w[:y] += w[:y]<=>0
      end
    end
  end

  #
  # 現在の盤面に与えられた石を置けるか判定し、
  #   配置可能な場合 :change
  #   配置不可&&全て埋まってれば :finish 
  #   配置不可&&全て埋まってない :pass,
  def next_action(stone)
    0.upto 7 do |x|
      0.upto 7 do |y|
        return :change if where_reversible(x,y,stone.clr).size > 0
      end
    end
    if @board.filled?
      :finish
    else
      :pass
    end
  end

end


# -------------------------------------------------
# BoardClass
# -------------------------------------------------
class Board
  attr_accessor :self

  #
  # 
  def initialize
    @self = Array.new(8).map{Array.new(8)}
  end

  #
  # 石の配置
  def placing(x, y, s); @self[x][y] = s; end

  #
  # 指定位置のStoneインスタンスを返却
  def stone(x, y); @self[x][y]; end

  #
  # 盤上が全て埋まっているか
  def filled?; return !(@self.flatten.include?(nil)); end
  
  #
  # Board情報を配列で返却(JSON変換用)
  def to_a; @self; end

  #
  # 盤上情報を文字列に変更
  def to_s; "#{@self}"; end
  alias inspect to_s

  #
  # 盤上情報をCLIに出力
  def screen
    $log.debug "[BOARD]"
    @self.map do |row|
      _row = row.map{|s| s ? s.to_s : "X"}.join
      $log.debug _row
    end
  end

  #
  #
  def count(clr)
    return @self.flatten.join('').count("#{clr}")
  end

end


# -------------------------------------------------
# StoneClass
# -------------------------------------------------
class Stone
  attr_accessor :clr
  
  #
  #
  def initialize(clr); @clr = clr; end
  
  #
  #
  def reverse; @clr = @clr==:w ? :b : :w; end

  #
  #
  def eql? other; @clr.eql? other.clr; end

  #
  #
  def other; return Stone.new clr = @clr==:w ? :b : :w; end

  #
  # 石色を文字列で返却
  def to_s; "#{@clr}"; end
  alias inspect to_s

end


# -------------------------------------------------
# main
# -------------------------------------------------
# option
option = {debug: false}
OptionParser.new do |opt|
  opt.on('--port=[VALUE]', '[int] port number (default: 8088)'){|v| option[:port] = v}
  opt.on('--debug',        '[ - ] logging debug log'){|v| option[:debug] = v}
  opt.parse!(ARGV)
end

# logger
$log = Object.new
def $log.info(msg);  puts "[INFO ] #{msg}"; end
def $log.error(msg); puts "[ERROR] #{msg}"; end
if option[:debug]
  def $log.debug(msg); puts "[DEBUG] #{msg}"; end
else
  def $log.debug(msg); end
end
$log.debug "MODE DEBUG"

# start up server
Server.new port = option[:port] ? option[:port] : DEFAULT_PORT