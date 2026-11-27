module Coop
  @root = Dir.pwd
  @dir = File.join(@root, "coop")
  @off = true
  @frame = 0
  @peers = {}
  @page = 0
  @id = -1
  @leader = 0
  @link = nil
  @dead = false
  @errors = 0
  @downed = []
  @rev = 0
  @vis = 0

  def self.dir
    @dir
  end

  def self.log(msg)
    begin
      Dir.mkdir(@dir) unless File.directory?(@dir)
      File.open(File.join(@dir, "log.txt"), "ab") do |f|
        f.write("#{Time.now.strftime('%H:%M:%S')} #{msg}\n".encode("UTF-8"))
      end
    rescue
    end
  end

  def self.b64(s)
    [s.to_s].pack("m0")
  end

  def self.unb64(s)
    s.to_s.unpack("m").first.to_s.force_encoding("UTF-8")
  rescue
    ""
  end

  def self.read_cfg
    path = File.join(@dir, "session.cfg")
    return nil unless File.exist?(path)
    raw = File.open(path, "rb") { |f| f.read }
    h = {}
    raw.force_encoding("UTF-8").split("\n").each do |line|
      line = line.strip
      next if line.empty? || line[0, 1] == "#"
      k, v = line.split("=", 2)
      h[k.strip.to_sym] = v.to_s.strip if k && v
    end
    h
  rescue
    nil
  end

  def self.boot
    Dir.mkdir(@dir) unless File.directory?(@dir)
    @cfg = ENV["bs2mp"] == "1" ? read_cfg : nil
    if @cfg.nil?
      @off = true
      return
    end
    @off = false
    @role = (@cfg[:role] == "host") ? :host : :guest
    @name = @cfg[:name].to_s
    @gfx = @cfg[:gfx].to_s
    @gfx_idx = @cfg[:idx].to_i
    @face = @cfg[:face].to_s
    @fidx = @cfg[:fidx].to_i
    @ncol = @cfg[:ncol].to_s =~ /\A[0-9a-fA-F]{6}\z/ ? @cfg[:ncol].to_s : "ebebf5"
    @trail_leader = Trail.new
    @pending = nil
    @display = nil
    @msg_sig = nil
    @msg_open = false
    @msg_page = -1
    @sent_hello = nil
    @sw_out = {}
    @var_out = {}
    @ssw_out = {}
    @party_sig = nil
    @ev_last = {}
    @ev_t = {}
    @ev_walk = {}
    @ev_map = 0
    @battle_ids = []
    @battle_cmds = {}
    @battle_map = []
    @in_battle = false
    @my_actor = nil
    @battle_rng = nil
    @pending_seed = nil
    @plan_ready = false
    @saved_party = nil
    @saved_actors = nil
    @saved_data = nil
    @turn_actor = nil
    @turn_frames = 0
    @menu_actor = nil
    @plans = []
    @pos_q = []
    @host_map = 0
    @arrived_map = 0
    @req_at = -9999
    @resync_req = false
    @last_full = -9999
    @last_pos = nil
    @last_msg = nil
    log "loaded role=#{@role} #{@cfg[:addr]}:#{@cfg[:port]} name=#{@name} gfx=#{@gfx} idx=#{@gfx_idx}"
    begin
      File.open(File.join(@dir, "loaded.txt"), "wb") { |f| f.write("ok #{Time.now}\n".encode("UTF-8")) }
    rescue
    end
  end

  def self.off?
    @off
  end

  def self.host?
    !@off && @role == :host
  end

  def self.guest?
    !@off && @role == :guest
  end

  def self.live?
    !@off && !@link.nil? && @link.open?
  end

  def self.my_id
    @id
  end

  def self.peers
    @peers
  end

  def self.leader
    @leader
  end

  def self.trail_leader
    @trail_leader
  end

  def self.display
    @display
  end

  def self.pending
    @pending
  end

  def self.auto?
    @auto
  end

  def self.mark_auto
    @auto = true
  end

  def self.host_look
    return nil unless host?
    return nil if @gfx.to_s.empty?
    [@gfx, @gfx_idx]
  end

  def self.profile
    if host?
      a = ($game_party.members[0] rescue nil)
      if a
        n = @name.to_s
        n = a.name.to_s if n.empty?
        look = host_look
        return [n, look[0], look[1]] if look
        g = a.character_name.to_s
        return [n, g, a.character_index.to_i] unless g.empty?
      end
    end
    [@name, @gfx, @gfx_idx]
  end

  def self.emit(msg)
    @link.write(msg) if live?
  end

  def self.say_hello
    return unless live?
    return if @id < 0
    n, g, i = profile
    @peers[@id] = { :name => n, :gfx => g, :idx => i, :col => @ncol, :face => @face, :fidx => @fidx }
    @sent_hello = "#{n}|#{g}|#{i}"
    Render.invalidate
    emit("hello|#{@id}|#{b64(n)}|#{b64(g)}|#{i}|#{@ncol}|#{b64(@face)}|#{@fidx}")
    note_party
  end

  def self.note_party
    File.open(File.join(@dir, "party.txt"), "wb") { |f| f.write("#{@peers.size}|#{(@peers[@leader] || {})[:name]}".encode("UTF-8")) }
  rescue
    nil
  end

  def self.note_page(text, win = nil)
    return unless host? && live?
    gm = $game_message
    return unless gm
    @page += 1
    @msg_open = true
    t = text.to_s
    cut = t.index("\f")
    t = t[0, cut] if cut
    @last_msg = "msg|#{@id}|#{@page}|#{b64(gm.face_name)}|#{gm.face_index}|#{gm.background}|#{gm.position}|" +
                "#{b64(t)}|#{b64(gm.choices.join("\x1e"))}|#{b64(speaker(win))}"
    emit(@last_msg)
  end

  def self.world_fx
    m = $game_map
    [($game_system.rich_fog rescue nil), (m.bmsp_fog rescue nil),
     [:@parallax_name, :@parallax_loop_x, :@parallax_loop_y, :@parallax_sx, :@parallax_sy].collect { |v| m.instance_variable_get(v) },
     m.instance_variable_get(:@tileset_id)]
  end

  def self.send_fx
    return unless host? && live?
    d = Marshal.dump([$game_map.map_id, world_fx])
    return if d == @fx_out
    @fx_out = d
    emit("fx|" + [d].pack("m0"))
  end

  def self.apply_fx
    return unless @fx_in && @fx_in[0] == $game_map.map_id
    fx = @fx_in[1]
    @fx_in = nil
    m = $game_map
    $game_system.rich_fog = fx[0] if !fx[0].nil? && $game_system.respond_to?(:rich_fog=)
    m.bmsp_fog = fx[1].dup if fx[1] && m.respond_to?(:bmsp_fog=)
    if fx[2] != [:@parallax_name, :@parallax_loop_x, :@parallax_loop_y, :@parallax_sx, :@parallax_sy].collect { |v| m.instance_variable_get(v) }
      m.change_parallax(*fx[2])
    end
    m.change_tileset(fx[3]) if fx[3] && fx[3] != m.instance_variable_get(:@tileset_id)
    log("fx applied rich=#{fx[0].inspect} fog=#{fx[1] && fx[1][:file].inspect}") if @cfg[:heartbeat] == "1"
  rescue => e
    log "fx apply failed #{e.class}: #{e.message}"
  end

  def self.quiet_battle?
    guest? && battle_on? && @in_battle
  end

  def self.note_noise
    emit("noise") if host? && live?
  end

  def self.note_fast
    return unless host? && live?
    emit("mfast|#{@page}")
  end

  def self.note_bfast(on)
    return unless host? && live?
    on = on ? true : false
    return if on == @bfast_out
    @bfast_out = on
    emit("bfast|#{on ? 1 : 0}")
  end

  def self.remote_fast?
    @bfast_in ? true : false
  end

  def self.speaker(win)
    nw = (win.instance_variable_get(:@name_windows) rescue nil)
    return "" unless nw.is_a?(Hash)
    nw.each { |k, w| return k.to_s if w.visible && !w.disposed? }
    ""
  end

  def self.request_resync
    @want_req = true
    pump_resync
  end

  def self.pump_resync
    return unless @want_req
    return unless guest? && live? && @id >= 0
    return if @frame - @req_at < 30
    @want_req = false
    @req_at = @frame
    log "resync request map=#{$game_map.map_id}"
    emit("req|#{@id}")
  end

  def self.full_resync
    return unless host? && live?
    return if @in_battle
    return if ($game_map.map_id.to_i rescue 0) <= 0
    @last_full = @frame
    @ev_last = {}
    @last_pos = nil
    @fx_out = nil
    flush_changes
    world_snapshot
    Render.pictures_snapshot
    Render.effects_snapshot
    send_party_data(true)
    if @msg_open && @last_msg && $game_message && $game_message.visible
      emit(@last_msg)
    end
  end

  def self.tick
    return if @off || @dead
    @frame += 1
    if @cfg[:heartbeat] == "1" && @frame % 120 == 0
      log("hb #{@frame}")
    end
    begin
      ensure_link
      if live?
        @link.poll.each { |line| handle(line) }
        if @frame % 30 == 0
          n, g, i = profile
          if "#{n}|#{g}|#{i}" != @sent_hello && !n.to_s.empty?
            say_hello
          end
        end
        host_tick if host?
        guest_tick if guest?
      end
      watch_battle
      if @cfg[:demoequip] == "1" && SceneManager.scene.is_a?(Scene_Equip) && (@de = @de.to_i + 1) % 60 == 0
        log("demo leaving equip screen")
        SceneManager.return
      end
      dummy_key if host?
      if host? && @cfg[:demomortal] && @in_battle
        @bt = @bt.to_i + 1
        make_mortal if @bt == @cfg[:demomortal].to_i
      end
      if host? && @cfg[:demowin] && @in_battle
        @bw = @bw.to_i + 1
        $game_troop.members.each { |e| e.add_state(e.death_state_id) } if @bw == @cfg[:demowin].to_i
      end
      finish_battle_cleanup
      Render.frame
      Render.hud_frame
      Chat.update
    rescue => e
      @errors += 1
      if @errors <= 3
        log "tick error #{e.class}: #{e.message}"
        (e.backtrace || [])[0, 8].each { |b| log "  #{b}" }
      end
      if @errors > 40 && !@dead
        @dead = true
        log "sync halted after #{@errors} errors"
      end
    end
  end

  def self.make_mortal
    return unless @imm
    @imm = false
    $game_troop.members.each { |e| e.instance_variable_set(:@coop_imm, false) }
    emit("bmortal") if live?
    log("dummy mortal")
  end

  def self.dummy_key
    return unless Input.trigger?(:F5)
    sc = SceneManager.scene
    if sc.is_a?(Scene_Battle)
      make_mortal
    elsif sc.is_a?(Scene_Map) && !$game_map.interpreter.running? && !$game_message.busy? && !$game_player.moving?
      log("dummy battle")
      @imm = true
      BattleManager.setup(1, true, false)
      $game_troop.members.each { |e| e.instance_variable_set(:@coop_imm, true) }
      SceneManager.call(Scene_Battle)
    end
  end

  def self.ensure_link
    return if live?
    return if @frame % 120 != 1
    @link = Link.new(@cfg[:addr].to_s, @cfg[:port].to_i)
    if @link.open
      log "socket open"
      @sent_hello = nil
      emit("auth|#{host? ? 'host' : 'guest'}")
      Render.hud "connected, waiting for room"
    else
      log "connect failed"
      Render.hud "cannot reach #{@cfg[:addr]}:#{@cfg[:port]}"
    end
  end

  def self.handle(line)
    parts = line.split("|")
    case parts[0]
    when "welcome"
      @id = parts[1].to_i
      @leader = parts[2].to_i
      log "welcome id=#{@id} leader=#{@leader}"
      say_hello
      if host?
        @resync_req = true
      else
        @arrived_map = 0
        @pos_q = []
        @mine_sent = false
        request_resync
      end
      Render.hud "#{@id == @leader ? 'leading' : 'joined'} - 1/4"
    when "wait"
      Render.hud "waiting for the host to start"
    when "full"
      log "room full"
      Render.hud "party is full (4 max)"
    when "hostgone"
      if guest? && @orig_party
        $game_party.instance_variable_set(:@actors, @orig_party)
        @orig_party = nil
      end
      log "host gone"
      Render.hud "host left"
      @link.close if @link
    when "hello"
      pid = parts[1].to_i
      @peers[pid] = { :name => unb64(parts[2]), :gfx => unb64(parts[3]), :idx => parts[4].to_i, :col => parts[5].to_s,
                      :face => unb64(parts[6]), :fidx => parts[7].to_i }
      Render.invalidate
      Render.hud "party #{@peers.size}/4"
      note_party
      if host?
        ensure_guest_party
        @resync_req = true
      end
    when "mine"
      if host?
        @chars ||= {}
        @chars[parts[1].to_i] = Marshal.load(parts[2].to_s.unpack("m").first)
        ensure_guest_party
        log "guest #{parts[1]} brought lv #{@chars[parts[1].to_i][0].level} party=#{$game_party.members.size}"
        @resync_req = true
      end
    when "seat"
      if guest? && parts[1].to_i == @id
        Render.hud(parts[2] == "1" ? "you're back in the party" : "party is full, you're spectating")
        log("seat #{parts[2]}") if @cfg[:heartbeat] == "1"
      end
    when "down"
      was = @downed.include?(@id)
      @downed = parts[1].to_s.split(",").collect { |x| x.to_i }
      if guest? && was != @downed.include?(@id)
        Render.hud(was ? "you've been revived" : "you're dead, rest at a campfire or get revived")
        log("down #{!was}") if @cfg[:heartbeat] == "1"
      end
    when "gear"
      apply_gear(parts[1].to_i, parts[2]) if host?
    when "use"
      apply_use(parts[1].to_i, parts[2].to_i, parts[3].to_s) if host?
    when "char"
      save_char(parts[2].to_s) if guest? && parts[1].to_i == @id
    when "leave"
      pid = parts[1].to_i
      @peers.delete(pid)
      remove_guest(pid) if host?
      log "peer #{pid} left party=#{($game_party.members.size rescue 0)}" if host?
      Render.invalidate
      Render.hud "party #{@peers.size}/4"
      note_party
    when "pos"
      if guest?
        map = parts[2].to_i
        px = parts[5].to_f
        py = parts[6].to_f
        return if map <= 0
        if map != @host_map
          log "host is on map #{map} (mine #{$game_map.map_id})"
          @host_map = map
          @arrived_map = 0
        end
        if map != $game_map.map_id
          @pending = [map, px, py, parts[7].to_i]
          @pos_q = []
          @trail_leader.clear
        else
          @pos_q << [parts[3].to_f, parts[4].to_f, px, py, parts[7].to_i]
        end
      end
    when "map"
      if guest?
        @pending = [parts[2].to_i, parts[3].to_f, parts[4].to_f, parts[5].to_i]
        @trail_leader.clear
      end
    when "msg"
      if guest?
        log("msg page #{parts[2]}: #{unb64(parts[7])[0, 40].inspect}") if @cfg[:heartbeat] == "1"
        b = Render.box
        b.feed(parts[2].to_i, unb64(parts[3]), parts[4].to_i, parts[5].to_i, parts[6].to_i,
               unb64(parts[7]), unb64(parts[8]), unb64(parts[9])) if b
      end
    when "fx"
      if guest?
        @fx_in = Marshal.load(parts[1].to_s.unpack("m").first)
        apply_fx
      end
    when "noise"
      $game_temp.brain_noise = true if guest? && $game_temp.respond_to?(:brain_noise=)
    when "mfast"
      if guest?
        b = Render.box
        b.fast(parts[1].to_i) if b
        log("mfast #{parts[1]}") if @cfg[:heartbeat] == "1"
      end
    when "bfast"
      @bfast_in = parts[1] == "1" if guest?
      log("bfast #{parts[1]}") if guest? && @cfg[:heartbeat] == "1"
    when "msgclose"
      if guest?
        b = Render.box
        b.finish(parts[2].to_i) if b
      end
    when "req"
      @resync_req = true if host?
    when "pdata"
      apply_party_data(parts[1]) if guest? && !@in_battle
    when "world"
      apply_world(parts) if guest? && !@in_battle
    when "bmap"
      if guest?
        @my_actor = nil
        (parts[1] || "").split(",").each do |pair|
          pid, aid = pair.split(":")
          @my_actor = aid.to_i if pid.to_i == my_id
        end
      end
    when "bsync"
      battle_guest_begin(parts) if guest?
    when "bplan"
      battle_guest_plan(parts) if guest?
    when "bfreeze"
      if guest? && SceneManager.scene.is_a?(Scene_Battle)
        SceneManager.scene.instance_variable_set(:@coop_freeze, parts[1] == "1")
      end
    when "bguestturn"
      if guest?
        log("bguestturn arrived #{parts[1]}")
        focus_self && SceneManager.scene.is_a?(Scene_Battle)
        SceneManager.scene.instance_variable_set(:@force_guest_turn, true)
      end
    when "bcmd"
      if host?
        aid = parts[1].to_i
        if battle_actor?(aid) && @collect_ids && @collect_ids.first.to_i == aid
          codes = parts[2..-1].collect { |row| row.split(":").collect { |x| x.to_i } }
          @battle_cmds[aid] = codes
        end
      end
    when "bfinal"
      battle_final(parts[1].to_s)
    when "bmortal"
      $game_troop.members.each { |e| e.instance_variable_set(:@coop_imm, false) } if guest?
    when "bend"
      @bfast_in = false
      if guest?
        log("host ended the battle")
        sc = SceneManager.scene
        sc.instance_variable_set(:@coop_leave, true) if sc.is_a?(Scene_Battle)
      end
    when "ssw"
      if guest? && $game_self_switches && !@in_battle
        key = [parts[1].to_i, parts[2].to_i, unb64(parts[3])]
        $game_self_switches[key] = (parts[4] == "1")
        if $game_map.map_id == key[0]
          e = ($game_map.events[key[1]] rescue nil)
          e.refresh if e
        end
      end
    when "sswb"
      if guest? && $game_self_switches && !@in_battle
        (parts[1] || "").split(",").each do |row|
          m, e, k, v = row.split(":")
          key = [m.to_i, e.to_i, unb64(k)]
          $game_self_switches[key] = (v == "1")
          if $game_map.map_id == key[0]
            ev = ($game_map.events[key[1]] rescue nil)
            ev.refresh if ev
          end
        end
      end
    when "aud"
      Render.apply_audio(parts) if guest?
      log("aud #{parts[1]} #{unb64(parts[2]) if parts[2]}") if guest? && @cfg[:heartbeat] == "1" && parts[1] == "se"
    when "weather"
      Render.apply_weather(parts) if guest?
    when "evb"
      if guest? && !@in_battle && parts[1].to_i == $game_map.map_id
        (parts[2] || "").split(";").each { |row| apply_event_row(row, false) }
      end
    when "evfx"
      if guest? && !@in_battle && parts[1].to_i == $game_map.map_id
        e = ($game_map.events[parts[2].to_i] rescue nil)
        if e && parts[3] == "a"
          e.animation_id = parts[4].to_i
        elsif e
          e.balloon_id = parts[4].to_i
        end
        log("evfx #{parts[2]} #{parts[3]}#{parts[4]}") if @cfg[:heartbeat] == "1"
      end
    when "evgone"
      if guest? && !@in_battle && parts[1].to_i == $game_map.map_id
        id = parts[2].to_i
        e = ($game_map.events[id] rescue nil)
        e.erase if e
        t = @ev_t[id]
        t[:erased] = true if t
      end
    when "sw"
      if guest? && $game_switches && !@in_battle
        $game_switches[parts[1].to_i] = (parts[2] == "1")
      end
    when "swb"
      if guest? && $game_switches && !@in_battle
        (parts[1] || "").split(",").each do |row|
          id, v = row.split(":")
          $game_switches[id.to_i] = (v == "1") if id
        end
      end
    when "varb"
      if guest? && $game_variables && !@in_battle
        (parts[1] || "").split(",").each do |row|
          id, raw = row.split(":")
          next unless id && raw
          v = (Marshal.load(raw.unpack("m").first) rescue nil)
          $game_variables[id.to_i] = v
        end
      end
    when "chat"
      Chat.add(unb64(parts[2]), parts[3].to_s, unb64(parts[4]))
      Render.say(parts[1].to_i, unb64(parts[4]), parts[3].to_s)
      log("chat #{unb64(parts[2])}: #{unb64(parts[4])}") if @cfg[:heartbeat] == "1"
    when "pic"
      Render.apply_picture(parts) if guest?
    when "picset"
      Render.apply_picture_set(parts) if guest?
    when "tone"
      Render.apply_tone(parts) if guest?
    when "flash"
      Render.apply_flash(parts) if guest?
    when "shake"
      Render.apply_shake(parts) if guest?
    end
  end

  def self.host_tick
    p = $game_player
    return unless p
    return if $game_map.map_id.to_i <= 0
    if !@look_done && host_look
      @look_done = true
      p.refresh
    end
    host_face if @frame % 30 == 0
    pos = "#{$game_map.map_id}|" + sprintf("%.4f|%.4f|%.3f|%.3f", $game_map.display_x, $game_map.display_y,
                                           p.real_x, p.real_y) + "|#{p.direction}"
    if pos != @last_pos || @frame % 30 == 0
      @last_pos = pos
      emit("pos|#{@id}|#{pos}")
    end
    @trail_leader.feed(p.real_x * 32.0, p.real_y * 32.0, p.direction)
    if @cfg[:demo] == "world" && host?
      @demo_w = (@demo_w || 0) + 1
      if @demo_w % 180 == 0
        v = !$game_switches[10]
        $game_switches[10] = v
        log("demo switch10=#{v}")
      end
    end
    if @cfg[:demoseat] == "1"
      @ds = @ds.to_i + 1
      if @ds == 360
        have = $game_party.instance_variable_get(:@actors)
        @dc = (2..200).select { |i| $data_actors[i] && !have.include?(i) && ($game_actors[i].mhp rescue 0) > 0 }.first(3)
        @dc.each { |i| $game_party.add_actor(i) }
        log("demo companions joined #{@dc.inspect}")
      elsif @ds == 560
        (@dc || []).each { |i| $game_party.remove_actor(i) }
        log("demo companions left")
      end
    end
    if @cfg[:demoitem] == "1" && !(@party_map || []).empty? && (@di = @di.to_i + 1) == 200
      ga = $game_actors[@party_map[0].split(":")[1].to_i]
      it = $game_party.items.find { |x| x.consumable && ga.usable?(x) }
      if it
        n = $game_party.item_number(it)
        ga.use_item(it)
        log("demo item #{it.id} guest usable=true host bag #{n}->#{$game_party.item_number(it)}")
      else
        log("demo item none usable #{$game_party.items.size}")
      end
    end
    if @cfg[:demoheal] == "1" && !(@party_map || []).empty? && (@dh = @dh.to_i + 1) == 200
      $game_party.members[0].hp = 1
      log("demo lead hurt hp=#{$game_party.members[0].hp}")
    end
    if @cfg[:demoheal] == "1" && (@dh.to_i == 900 || @dh.to_i == 1500)
      a = $game_actors[slot_aid(1)] rescue nil
      log("demo host sees guest equips=#{a.equips.collect { |e| e ? e.id : 0 }.inspect} bag1=#{(@chars[1][1][0][1] rescue nil)}") if a
    end
    if @cfg[:demodown] == "1" && !(@party_map || []).empty?
      @dd = @dd.to_i + 1
      a = $game_actors[@party_map[0].split(":")[1].to_i]
      if @dd == 300
        a.add_state(a.death_state_id)
        log("demo guest killed hp=#{a.hp}")
      elsif @dd == 420
        a.recover_all
        a.hp = 50
        a.remove_state(a.death_state_id)
        log("demo script heal blocked=#{a.death_state?} hp=#{a.hp}")
      elsif @dd == 540
        i = Game_Interpreter.new
        i.instance_variable_set(:@params, [0, 0])
        i.command_314
        log("demo campfire dead=#{a.death_state?} hp=#{a.hp}")
      end
    end
    if @cfg[:demo] == "walk"
      @demo_k = (@demo_k || 0) + 1
      if @demo_k % 40 == 0 && !p.moving? && !$game_message.busy?
        dirs = [2, 4, 6, 8]
        p.move_straight(dirs[(@demo_k / 40) % 4])
      end
      if @demo_k == 300
        ev = $game_map.events.values.find { |x| (x.x - p.x).abs + (x.y - p.y).abs < 12 && !x.character_name.empty? }
        if ev
          ev.jump(0, 0)
          ev.balloon_id = 1
          log("demo jump ev #{ev.id}")
        end
      end
      if @demo_k == 340
        $data_system.sounds[1].play
        Sound.play_cursor
      end
      if @demo_k == 200 && $game_system.respond_to?(:rich_fog=)
        $game_system.rich_fog = true
        log("demo rich fog on")
      end
      if @demo_k == 428
        mw = SceneManager.scene.instance_variable_get(:@message_window)
        mw.instance_variable_set(:@show_fast, true) if mw
      end
      if @demo_k == 600 && @party_map && !@party_map.empty?
        pid, aid = @party_map[0].split(":").collect { |x| x.to_i }
        sa = $game_actors[aid]
        c = @chars[pid]
        log("demo slot lv=#{sa.level} equips=#{sa.equips.collect { |e| e ? e.id : 0 }.inspect} host lead equips=#{$game_party.members[0].equips.collect { |e| e ? e.id : 0 }.inspect}")
        iid = c[1][0].keys.find { |k| $data_items[k] && $data_items[k].consumable }
        if iid
          it = $data_items[iid]
          hb = $game_party.item_number(it)
          gb = c[1][0][iid].to_i
          sa.consume_item(it)
          log("demo bag item=#{iid} guest #{gb}->#{c[1][0][iid].to_i} host #{hb}->#{$game_party.item_number(it)} usable=#{sa.item_conditions_met?(it)}")
        else
          log("demo bag: guest has no consumable items")
        end
        send_chars
      end
      if @demo_k == 360
        Chat.instance_variable_set(:@buf, "hi from the host")
        Chat.say
      end
      if @demo_k == 420
        if (Cache.face("ノーデ") rescue nil)
          $game_message.face_name = "ノーデ"
          $game_message.face_index = 0
        end
        $game_message.background = 1
        $game_message.add("Co-op test line one.")
        $game_message.add('Second line, \C[2]coloured\C[0].')
        log("demo message shown")
      end
    end
    if @cfg[:demo] == "battle" && !@demo_battle
      @demo_t = (@demo_t || 0) + 1
      if @demo_t == 240
        @demo_battle = true
        log("demo battle start")
        $game_player.make_encounter_count
        BattleManager.setup(1, true, false)
        $game_troop.members.each { |e| e.instance_variable_set(:@hp, (@cfg[:demohp] || 1).to_i) }
        if @cfg[:demoimm] == "1"
          @imm = true
          $game_troop.members.each { |e| e.instance_variable_set(:@coop_imm, true) }
        end
        log("demo setup done")
        SceneManager.call(Scene_Battle)
        log("demo scene called")
      end
    end
    if @ev_map != $game_map.map_id
      @ev_map = $game_map.map_id
      @ev_last = {}
      @ev_walk = {}
      @resync_req = true
    end
    unless @in_battle
      flush_changes
      if @resync_at && @frame >= @resync_at
        @resync_at = nil
        @resync_req = true
      end
      if @resync_req && @frame - @last_full >= 20
        @resync_req = false
        full_resync
      end
      if @frame % 1800 == 0
        world_snapshot
        send_party_data
      end
      sync_events if @frame % 2 == 0
      send_fx if @frame % 10 == 0
      seat_guests if @frame % 30 == 0
      send_downed if @frame % 30 == 0
      send_party_data if @frame % 30 == 0
      watch_message
    end
    watch_message if @in_battle
  end

  def self.action_code(act)
    return [0, 0, -1] unless act && act.item
    item = (act.item rescue nil)
    return [2, 0, act.target_index.to_i] if act.respond_to?(:guard?) && act.guard?
    if item.is_a?(RPG::Skill)
      return [1, 0, act.target_index.to_i] if act.respond_to?(:attack?) && act.attack?
      return [3, item.id, act.target_index.to_i]
    end
    return [4, item.id, act.target_index.to_i] if item.is_a?(RPG::Item)
    [1, 0, act.target_index.to_i]
  end

  def self.apply_code(act, code)
    return unless act
    case code[0].to_i
    when 0
      act.clear
      return
    when 2 then act.set_guard
    when 3 then act.set_skill(code[1].to_i)
    when 4 then act.set_item(code[1].to_i)
    else act.set_attack
    end
    act.target_index = code[2].to_i
  end

  def self.actor_actions(actor)
    (actor.instance_variable_get(:@actions) rescue nil) || []
  end

  def self.battle_scene_begin
    return unless battle_on?
    seed = rand(1 << 30)
    @battle_rng = CoopRng.new(seed)
    data = {}
    @battle_ids.each { |id| data[id] = $data_actors[id] }
    actors = ($game_party.members rescue [])
    ab = [Marshal.dump(actors)].pack("m0")
    db = [Marshal.dump(data)].pack("m0")
    pre = (BattleManager.instance_variable_get(:@preemptive) ? 1 : 0)
    sur = (BattleManager.instance_variable_get(:@surprise) ? 1 : 0)
    troop = ($game_troop.instance_variable_get(:@troop_id) rescue 0).to_i
    log("battle sync troop=#{troop} seed=#{seed}")
    emit("bsync|#{troop}|#{seed}|#{pre}|#{sur}|#{ab}|#{db}|#{@cfg[:demo] == 'battle' ? 1 : 0}|#{@imm ? 1 : 0}") if live?
  end

  def self.install_seed
    return unless @pending_seed
    @battle_rng = CoopRng.new(@pending_seed)
    @pending_seed = nil
    log("battle rng installed")
  end

  def self.battle_guest_begin(parts)
    return unless battle_on?
    troop = parts[1].to_i
    @pending_seed = parts[2].to_i
    pre = parts[3] == "1"
    sur = parts[4] == "1"
    actors = Marshal.load(parts[5].to_s.unpack("m").first)
    data = Marshal.load(parts[6].to_s.unpack("m").first)
    battle_swap_in(actors, data)
    BattleManager.setup(troop, true, false)
    if parts[8] == "1"
      $game_troop.members.each { |e| e.instance_variable_set(:@coop_imm, true) }
    end
    if parts[7] == "1"
      $game_troop.members.each do |e|
        e.instance_variable_set(:@hp, 10000000)
        e.instance_variable_set(:@mhp, 10000000)
      end
    end
    BattleManager.instance_variable_set(:@preemptive, pre)
    BattleManager.instance_variable_set(:@surprise, sur)
    @in_battle = true
    log("battle guest begin troop=#{troop} actors=#{actors.size}")
    SceneManager.call(Scene_Battle)
  end

  def self.battle_swap_in(actors, data)
    battle_swap_out
    @saved_party = (($game_party.instance_variable_get(:@actors) rescue nil) || []).dup
    @saved_actors = {}
    @saved_data = {}
    data.each do |id, d|
      @saved_data[id] = $data_actors[id]
      $data_actors[id] = d
    end
    gd = $game_actors.instance_variable_get(:@data)
    actors.each do |a|
      id = a.instance_variable_get(:@actor_id)
      @saved_actors[id] = gd[id]
      gd[id] = a
    end
    ids = actors.collect { |a| a.instance_variable_get(:@actor_id) }
    $game_party.instance_variable_set(:@actors, ids)
  end

  def self.battle_swap_out
    return unless @saved_party
    $game_party.instance_variable_set(:@actors, @saved_party)
    gd = $game_actors.instance_variable_get(:@data)
    (@saved_actors || {}).each { |id, a| gd[id] = a }
    (@saved_data || {}).each { |id, d| $data_actors[id] = d }
    @saved_party = nil
    @saved_actors = nil
    @saved_data = nil
    @battle_rng = nil
    @pending_seed = nil
    @plan_ready = false
    @plans = []
    begin
      $game_player.refresh
    rescue
    end
  end

  def self.battle_guest_input
    aid = @my_actor
    return unless aid
    actor = ($game_actors[aid] rescue nil)
    return unless actor
    codes = actor_actions(actor).collect { |a| action_code(a) }
    body = codes.collect { |c| c.join(":") }.join("|")
    log("guest input #{actor.name} #{body}")
    emit("bcmd|#{aid}|#{body}") if live?
  end

  def self.battle_guest_plan(parts)
    return unless battle_on?
    unless SceneManager.scene.is_a?(Scene_Battle) || @in_battle
      log("guest plan ignored, no battle")
      return
    end
    @plans << [parts[1].to_s, parts[2].to_i, parts[3].to_s]
    @plan_ready = true
    log("guest plan queued (#{@plans.size})")
  end

  def self.apply_next_plan
    plan = @plans.shift
    @plan_ready = !@plans.empty?
    return unless plan
    entries, seed, state = plan
    apply_battle_state(state)
    codes = {}
    entries.split(";").each do |entry|
      kind, bid, idx, k, i, t = entry.split(":")
      b = battler_for(kind, bid.to_i)
      next unless b
      (codes[b] ||= [])[idx.to_i] = [k.to_i, i.to_i, t.to_i]
    end
    (($game_party.members rescue []) + ($game_troop.members rescue [])).each do |b|
      list = (codes[b] || []).collect do |c|
        act = Game_Action.new(b)
        apply_code(act, c || [0, 0, -1])
        act
      end
      b.instance_variable_set(:@actions, list)
    end
    @battle_rng = CoopRng.new(seed)
    log("guest plan applied seed=#{seed}")
  end

  def self.battler_for(kind, id)
    if kind == "E"
      ($game_troop.members[id] rescue nil)
    else
      ($game_actors[id] rescue nil)
    end
  end

  def self.bvars
    [:@hp, :@mp, :@tp, :@states, :@state_turns, :@buffs, :@buff_turns, :@ap, :@next_ap, :@turn_count,
     :@state_frames, :@act_chant, :@chant_action_forced, :@chant_count, :@chant_object, :@chant_states,
     :@chant_target_index, :@chant_type, :@max_chant_count, :@last_choice_target_index]
  end

  def self.battle_state_blob
    party = ($game_party.members rescue []).collect do |a|
      [a.actor_id, bvars.collect { |v| a.instance_variable_get(v) }]
    end
    troop = ($game_troop.members rescue []).collect do |e|
      [bvars.collect { |v| e.instance_variable_get(v) }, e.instance_variable_get(:@hidden),
       e.instance_variable_get(:@enemy_id)]
    end
    [Marshal.dump([party, troop])].pack("m0")
  end

  def self.apply_battle_state(str)
    return if str.to_s.empty?
    party, troop = Marshal.load(str.to_s.unpack("m").first)
    party.each do |aid, vals|
      a = ($game_actors[aid] rescue nil)
      next unless a
      bvars.each_with_index { |v, i| a.instance_variable_set(v, vals[i]) }
    end
    members = ($game_troop.members rescue [])
    troop.each_with_index do |row, i|
      e = members[i]
      next unless e
      vals, hidden, enemy_id = row
      bvars.each_with_index { |v, j| e.instance_variable_set(v, vals[j]) }
      e.instance_variable_set(:@hidden, hidden)
      e.instance_variable_set(:@enemy_id, enemy_id) if enemy_id
    end
  rescue => e
    log("battle state apply failed #{e.class}: #{e.message}")
  end

  def self.battle_host_plan
    entries = []
    ($game_party.members rescue []).each do |actor|
      actor_actions(actor).each_with_index do |act, i|
        c = action_code(act)
        entries << "A:#{actor.actor_id}:#{i}:#{c[0]}:#{c[1]}:#{c[2]}"
      end
    end
    ($game_troop.members rescue []).each_with_index do |enemy, ei|
      actor_actions(enemy).each_with_index do |act, i|
        c = action_code(act)
        entries << "E:#{ei}:#{i}:#{c[0]}:#{c[1]}:#{c[2]}"
      end
    end
    seed = real_rand(1 << 30)
    state = battle_state_blob
    @battle_rng = CoopRng.new(seed)
    emit("bplan|#{entries.join(';')}|#{seed}|#{state}") if live?
  end

  def self.battle_collect_begin(scene)
    @collect_scene = scene
    @collect_ids = []
    act = (BattleManager.action_battler rescue nil)
    ib = (BattleManager.input_battler rescue nil)
    if act.is_a?(Game_Actor) && act.equal?(ib)
      aid = act.actor_id
      if @battle_ids.include?(aid)
        actual = ($game_actors[aid] rescue nil)
        @collect_ids << aid if actual && actual.alive?
      end
    end
    battle_collect_next
  end

  def self.battle_collect_next
    sc = @collect_scene
    return unless sc
    while !@collect_ids.empty?
      aid = @collect_ids.first
      actor = ($game_actors[aid] rescue nil)
      unless actor && actor.alive?
        @collect_ids.shift
        next
      end
      cmd = @battle_cmds.delete(aid)
      if cmd
        @collect_ids.shift
        battle_apply_codes(actor, cmd)
        next
      end
      peer = nil
      @battle_map.each do |pair|
        pid, pack = pair.split(":")
        peer = pid.to_i if pack.to_i == aid
      end
      unless live? && peer && @peers[peer]
        @collect_ids.shift
        battle_apply_codes(actor, [[1, 0, -1]])
        next
      end
      sc.instance_variable_set(:@coop_wait, actor)
      @turn_frames = 0
      Render.wait_show("Waiting for #{actor.name}...")
      log("guest turn request #{actor.name}")
      emit("bguestturn|#{aid}")
      return
    end
    @collect_scene = nil
    Render.wait_hide
    battle_host_plan
    emit("bfreeze|0") if live?
    sc.instance_variable_set(:@coop_wait, nil)
    sc.instance_variable_set(:@coop_collect, false)
    sc.coop_turn_start
  end

  def self.battle_apply_codes(actor, codes)
    acts = actor_actions(actor)
    acts.push(Game_Action.new(actor)) while acts.size < codes.size
    acts.slice!(codes.size..-1) if codes.size > 0
    log("apply #{actor.name} #{codes.collect { |c| c.join(':') }.join('|')}") if @cfg[:heartbeat] == "1"
    codes.each_with_index do |c, i|
      apply_code(acts[i], c) if acts[i]
    end
    @turn_actor = nil
  end

  def self.battle_host_poll(scene, actor)
    cmd = @battle_cmds.delete(actor.actor_id)
    if cmd
      battle_apply_codes(actor, cmd)
      @collect_ids.shift if @collect_ids.first == actor.actor_id
      battle_collect_next
      return
    end
    @turn_frames += 1
    @turn_frames = 900 unless slot_pid(actor.actor_id)
    if @turn_frames % 60 == 0
      left = [15 - @turn_frames / 60, 0].max
      Render.wait_show("Waiting for #{actor.name}... #{left}s")
    end
    return unless @turn_frames >= 900
    log("turn timeout #{actor.name}")
    battle_apply_codes(actor, [[1, 0, -1]])
    @turn_frames = 0
    @collect_ids.shift if @collect_ids.first == actor.actor_id
    battle_collect_next
  end

  def self.ncol
    @ncol
  end

  def self.hexcol(h, a = 255)
    v = h.to_s.to_i(16)
    v = 0xebebf5 if h.to_s.empty?
    Color.new((v >> 16) & 255, (v >> 8) & 255, v & 255, a)
  end

  def self.input_ok?
    focused_input? && !Chat.open?
  end

  def self.focused_input?
    @fw ||= [Win32API.new("user32", "GetForegroundWindow", "", "L"),
             Win32API.new("user32", "GetWindowThreadProcessId", "LP", "L"),
             Win32API.new("kernel32", "GetCurrentProcessId", "", "L").call]
    buf = [0].pack("L")
    @fw[1].call(@fw[0].call, buf)
    buf.unpack("L")[0] == @fw[2]
  rescue
    true
  end

  def self.focus_self
    return nil if @win_api == false
    begin
      @win_api ||= {
        :fwx => Win32API.new("user32", "FindWindowExA", "LLPL", "L"),
        :gwtid => Win32API.new("user32", "GetWindowThreadProcessId", "LP", "L"),
        :gpid => Win32API.new("kernel32", "GetCurrentProcessId", "", "L"),
        :sfw => Win32API.new("user32", "SetForegroundWindow", "L", "L"),
        :show => Win32API.new("user32", "ShowWindow", "LI", "L")
      }
    rescue
      @win_api = false
      return nil
    end
    api = @win_api
    pid = api[:gpid].call
    buf = [0].pack("L")
    h = api[:fwx].call(0, 0, "RGSS Player", 0)
    while h != 0
      api[:gwtid].call(h, buf)
      if buf.unpack("L")[0] == pid
        api[:show].call(h, 9)
        api[:sfw].call(h)
        return h
      end
      h = api[:fwx].call(0, h, "RGSS Player", 0)
    end
    nil
  end

  def self.battle_on?
    @cfg && @cfg[:battle] == "1"
  end

  def self.cfg
    @cfg || {}
  end

  def self.demo?
    @cfg && @cfg[:demo] == "battle"
  end

  def self.party_sig
    actors = ($game_party.members rescue [])
    actors.collect do |a|
      "#{a.actor_id}:#{a.name}:#{a.character_name}:#{a.character_index}:#{a.hp}:#{a.mp}:#{a.equips.collect { |e| e ? e.id : 0 }.join(',')}:#{a.states.collect { |x| x.id }.join(',')}"
    end.join("|")
  rescue
    ""
  end

  def self.send_party_data(force = false)
    return unless host? && live?
    return if @in_battle
    sig = party_sig
    return if !force && sig == @party_sig
    @party_sig = sig
    actors = ($game_party.members rescue [])
    clone = {}
    (@party_map || []).each do |pair|
      aid = pair.split(":")[1].to_i
      d = ($data_actors[aid] rescue nil)
      clone[aid] = d if d
    end
    blob = [Marshal.dump([actors, clone, @party_map || []])].pack("m0")
    emit("pdata|#{blob}")
  end

  def self.apply_party_data(str)
    return unless guest?
    if SceneManager.scene.is_a?(Scene_MenuBase)
      @pdata_later = str
      return
    end
    @pdata_later = nil
    actors, clone, pm = Marshal.load(str.to_s.unpack("m").first)
    (pm || []).each { |x| @my_actor = x.split(":")[1].to_i if x.split(":")[0].to_i == @id } unless @in_battle
    clone.each { |id, d| $data_actors[id] = d }
    gd = $game_actors.instance_variable_get(:@data)
    ids = []
    actors.each do |a|
      id = a.instance_variable_get(:@actor_id)
      gd[id] = a
      ids << id
    end
    $game_party.instance_variable_set(:@actors, ids)
    $game_player.refresh rescue nil
    hud_refresh
  end

  def self.hud_refresh
    sc = SceneManager.scene
    return unless sc
    sc.instance_variables.each do |v|
      w = sc.instance_variable_get(v)
      w.refresh if defined?(Window_KisekiStatus) && w.is_a?(Window_KisekiStatus)
    end
  rescue
  end

  def self.host_face
    return if @face.empty?
    a = ($game_party.members[0] rescue nil)
    return unless a
    return if a.face_name == @face && a.face_index == @fidx
    @face_orig = [a, a.face_name, a.face_index] unless @face_orig && @face_orig[0].equal?(a)
    a.instance_variable_set(:@face_name, @face)
    a.instance_variable_set(:@face_index, @fidx)
    hud_refresh
  end

  def self.face_guard_begin
    return nil unless host? && @face_orig
    a, n, i = @face_orig
    st = [a, a.face_name, a.face_index]
    a.instance_variable_set(:@face_name, n)
    a.instance_variable_set(:@face_index, i)
    st
  end

  def self.face_guard_end(st)
    return unless st
    st[0].instance_variable_set(:@face_name, st[1])
    st[0].instance_variable_set(:@face_index, st[2])
  end

  def self.world_snapshot
    return unless host? && live?
    return if @in_battle
    return if ($game_map.map_id.to_i rescue 0) <= 0
    sw = $game_switches.instance_variable_get(:@data)
    vars = $game_variables.instance_variable_get(:@data)
    ssw = $game_self_switches.instance_variable_get(:@data)
    blob = [Marshal.dump([sw, vars, ssw])].pack("m0")
    evs = []
    $game_map.events.each { |id, e| evs << event_row(id, e) }
    party = ($game_party.members rescue []).collect { |a| a.actor_id }
    roster = []
    lead_id = party[0] || 1
    (@party_map || []).each do |pair|
      pid, aid = pair.split(":")
      a = ($game_actors[aid.to_i] rescue nil)
      next unless a
      roster << "#{aid}:#{b64(a.name)}:#{b64(a.character_name)}:#{a.character_index}:#{lead_id}"
    end
    emit("world|#{$game_map.map_id}|#{blob}|#{evs.join(';')}|#{party.join(',')}|#{roster.join(';')}")
    log("world send ev=#{evs.size} map=#{$game_map.map_id}")
  end

  def self.apply_world(parts)
    return unless guest?
    map = parts[1].to_i
    return if map <= 0
    sw, vars, ssw = Marshal.load(parts[2].to_s.unpack("m").first)
    $game_switches.instance_variable_set(:@data, sw) if sw.is_a?(Array)
    $game_variables.instance_variable_set(:@data, vars) if vars.is_a?(Array)
    $game_self_switches.instance_variable_set(:@data, ssw) if ssw.is_a?(Hash)
    roster = (parts[5] || "").split(";")
    roster.each do |row|
      aid, name, gfx, idx, lead = row.split(":")
      next unless aid
      base = ($data_actors[lead.to_i] rescue nil)
      next unless base
      data = base.dup
      data.instance_variable_set(:@name, unb64(name))
      data.instance_variable_set(:@character_name, unb64(gfx))
      data.instance_variable_set(:@character_index, idx.to_i)
      $data_actors[aid.to_i] = data
    end
    party = (parts[4] || "").split(",").collect { |x| x.to_i }
    if party.size > 0
      @orig_party ||= (($game_party.instance_variable_get(:@actors) rescue []) || []).dup
      $game_party.instance_variable_set(:@actors, party)
    end
    $game_map.refresh
    log("world recv tgt=#{map} mine=#{$game_map.map_id}")
    if map == $game_map.map_id
      (parts[3] || "").split(";").each { |row| apply_event_row(row, true) }
    end
  end

  def self.event_row(id, e)
    er = e.instance_variable_get(:@erased) ? 1 : 0
    tr = e.transparent ? 1 : 0
    "#{id}:" + sprintf("%.3f:%.3f", e.real_x, e.real_y) +
      ":#{e.direction}:#{e.pattern}:#{b64(e.character_name)}:#{e.character_index}:#{e.opacity}:#{tr}:#{er}:#{e.tile_id}" +
      ":#{e.instance_variable_get(:@jump_count).to_i}:#{e.instance_variable_get(:@jump_peak).to_i}"
  end

  def self.apply_event_row(row, snap)
    f = row.split(":", -1)
    return if f.size < 11
    id = f[0].to_i
    e = ($game_map.events[id] rescue nil)
    return unless e
    t = {
      :x => f[1].to_f, :y => f[2].to_f, :dir => f[3].to_i, :pat => f[4].to_i,
      :gfx => unb64(f[5]), :idx => f[6].to_i, :op => f[7].to_i, :tr => f[8] == "1",
      :erased => f[9] == "1", :tile => f[10].to_i, :jc => f[11].to_i, :jp => f[12].to_i
    }
    log("ev #{id} jump") if t[:jc] > 0 && @ev_t[id] && @ev_t[id][:jc].to_i == 0 && @cfg[:heartbeat] == "1"
    @ev_t[id] = t
    if t[:erased]
      e.erase unless e.instance_variable_get(:@erased)
      return
    end
    if snap || (e.real_x - t[:x]).abs + (e.real_y - t[:y]).abs > 4
      e.instance_variable_set(:@real_x, t[:x])
      e.instance_variable_set(:@real_y, t[:y])
      e.instance_variable_set(:@x, t[:x].round)
      e.instance_variable_set(:@y, t[:y].round)
    end
    apply_event_look(e, t)
  end

  def self.apply_event_look(e, t)
    e.instance_variable_set(:@direction, t[:dir]) if e.direction != t[:dir]
    e.instance_variable_set(:@pattern, t[:pat]) if e.pattern != t[:pat]
    e.instance_variable_set(:@character_name, t[:gfx]) if e.character_name != t[:gfx]
    e.instance_variable_set(:@character_index, t[:idx]) if e.character_index != t[:idx]
    e.instance_variable_set(:@tile_id, t[:tile]) if e.tile_id != t[:tile]
    e.instance_variable_set(:@opacity, t[:op]) if e.opacity != t[:op]
    e.instance_variable_set(:@transparent, t[:tr]) if e.transparent != t[:tr]
    e.instance_variable_set(:@jump_count, t[:jc]) if e.instance_variable_get(:@jump_count) != t[:jc]
    e.instance_variable_set(:@jump_peak, t[:jp]) if e.instance_variable_get(:@jump_peak) != t[:jp]
  end

  def self.watch_battle
    inside = SceneManager.scene.is_a?(Scene_Battle)
    return if inside == @in_battle
    @in_battle = inside
    log("battle screen " + (inside ? "in" : "out"))
    if inside
      if host? && @msg_open
        @msg_open = false
        emit("msgclose|#{@id}|#{@page}") if live?
      end
      @msg_sig = nil
    else
      @cleanup_pending = true
    end
  end

  def self.finish_battle_cleanup
    return unless @cleanup_pending
    return unless SceneManager.scene.is_a?(Scene_Map)
    @cleanup_pending = false
    log("battle cleanup begin")
    @battle_rng = nil
    if host?
      @imm = false
      @end_msgs = false
      emit("bend") if live?
      cleanup_battle_actors
      (@drop || []).each { |aid| drop_actor(aid) unless slot_pid(aid) }
      @drop = []
      send_chars
      @resync_at = @frame + 150
    else
      battle_swap_out
    end
    log("battle cleanup end")
  end

  def self.ensure_guest_party
    return unless host? && live?
    return unless $game_party && $game_actors
    lead = ($game_party.members[0] rescue nil)
    return unless lead
    @party_map ||= []
    used = @party_map.collect { |pair| pair.split(":")[1].to_i }
    (@peers.keys.sort - [@leader]).each do |pid|
      next if @party_map.any? { |pair| pair.split(":")[0].to_i == pid }
      info = @peers[pid]
      next unless info
      own = (@chars || {})[pid]
      next unless own
      break if $game_party.members.size >= 4
      aid = 201
      aid += 1 while used.include?(aid)
      used << aid
      base = ($data_actors[own[0].actor_id] rescue nil) || ($data_actors[lead.actor_id] rescue nil)
      next unless base
      gname = info[:name].to_s
      gname = "Guest" if gname.empty?
      data = base.dup
      data.instance_variable_set(:@name, gname)
      data.instance_variable_set(:@character_name, info[:gfx].to_s)
      data.instance_variable_set(:@character_index, info[:idx].to_i)
      fc = info[:face].to_s.empty? ? face_for(info[:gfx].to_s, info[:idx].to_i) : [info[:face], info[:fidx]]
      if fc
        data.instance_variable_set(:@face_name, fc[0])
        data.instance_variable_set(:@face_index, fc[1])
      end
      $data_actors[aid] = data
      copy = (Marshal.load(Marshal.dump(own[0])) rescue nil)
      next unless copy
      copy.instance_variable_set(:@actor_id, aid)
      copy.instance_variable_set(:@name, gname)
      copy.instance_variable_set(:@character_name, info[:gfx].to_s)
      copy.instance_variable_set(:@character_index, info[:idx].to_i)
      if fc
        copy.instance_variable_set(:@face_name, fc[0])
        copy.instance_variable_set(:@face_index, fc[1])
      end
      copy.clear_actions
      $game_actors.instance_variable_get(:@data)[aid] = copy
      $game_party.add_actor(aid)
      @party_map << "#{pid}:#{aid}"
    end
    begin
      $game_player.followers.visible = false
    rescue
    end
  end

  def self.face_for(gfx, idx)
    list = ($data_actors[1, 200] || []).compact.select { |d| d.character_name == gfx && !d.face_name.to_s.empty? }
    d = list.find { |x| x.character_index == idx } || list.first
    d ? [d.face_name, d.face_index] : nil
  end

  def self.seat_guests
    return unless host? && live? && !@in_battle && $game_party
    ids = (@party_map || []).collect { |x| x.split(":")[1].to_i }
    story = ((($game_party.instance_variable_get(:@actors) rescue nil) || []) - ids).size
    room = [4 - story, 0].max
    while (@party_map || []).size > room
      pid, aid = @party_map.last.split(":").collect { |x| x.to_i }
      a = ($game_actors[aid] rescue nil)
      c = (@chars || {})[pid]
      if a && c
        orig = c[0].actor_id
        c[0] = Marshal.load(Marshal.dump(a))
        c[0].instance_variable_set(:@actor_id, orig)
      end
      send_chars
      remove_guest(pid)
      emit("seat|#{pid}|0")
      log "guest #{pid} benched, party full"
    end
    return unless (@party_map || []).size < room
    before = (@party_map || []).collect { |x| x.split(":")[0].to_i }
    ensure_guest_party
    ((@party_map || []).collect { |x| x.split(":")[0].to_i } - before).each do |pid|
      emit("seat|#{pid}|1")
      log "guest #{pid} back in the party"
    end
  end

  def self.send_gear
    a = (@my_actor && $game_actors[@my_actor]) rescue nil
    return unless a
    sig = Marshal.dump([a.equips.collect { |e| e ? e.id : 0 }, bag_of_party])
    return if sig == @gear_sig
    @gear_sig = sig
    emit("gear|#{@id}|#{[sig].pack('m0')}")
  end

  def self.apply_gear(pid, str)
    ids, bag = Marshal.load(str.to_s.unpack("m").first)
    aid = slot_aid(pid)
    c = (@chars || {})[pid]
    a = aid && ($game_actors[aid] rescue nil)
    return unless a && c
    a.equip_slots.each_with_index do |et, i|
      id = ids[i].to_i
      it = id > 0 ? (et == 0 ? $data_weapons[id] : $data_armors[id]) : nil
      a.force_change_equip(i, it) unless a.equips[i] == it
    end
    c[1] = bag
  end

  def self.send_use(item, targets)
    emit("use|#{@id}|#{item.id}|#{targets.collect { |t| t.actor_id }.join(',')}")
  end

  def self.apply_use(pid, iid, list)
    aid = slot_aid(pid)
    user = aid && ($game_actors[aid] rescue nil)
    item = $data_items[iid]
    return unless user && item
    list.split(",").each do |t|
      tg = ($game_actors[t.to_i] rescue nil)
      next unless tg && $game_party.members.include?(tg)
      item.repeats.times { tg.item_apply(user, item) }
    end
    log "guest #{pid} used #{item.name} on #{list} hp=#{list.split(',').collect { |t| ($game_actors[t.to_i].hp rescue 0) }.inspect}"
    hud_refresh
  end

  def self.slot_aid(pid)
    pair = (@party_map || []).find { |x| x.split(":")[0].to_i == pid }
    pair ? pair.split(":")[1].to_i : nil
  end

  def self.send_downed
    return if @in_battle
    d = (@party_map || []).select { |x| ($game_actors[x.split(":")[1].to_i].death_state? rescue false) }.collect { |x| x.split(":")[0].to_i }
    return if d == @downed && @frame % 300 != 0
    (d - @downed).each { |pid| log "guest #{pid} died" }
    (@downed - d).each { |pid| log "guest #{pid} revived" }
    @downed = d
    emit("down|#{d.join(',')}")
  end

  def self.downed
    @downed
  end

  def self.keep_dead?(a)
    host? && live? && @rev == 0 && a.death_state? && slot_pid(a.actor_id)
  end

  def self.revive_ok
    @rev += 1
    yield
  ensure
    @rev -= 1
  end

  def self.remove_guest(pid)
    return unless host?
    pair = (@party_map || []).find { |x| x.split(":")[0].to_i == pid }
    return unless pair
    @party_map.delete(pair)
    aid = pair.split(":")[1].to_i
    if @in_battle
      (@drop ||= []) << aid
      return
    end
    drop_actor(aid)
  end

  def self.drop_actor(aid)
    begin
      $game_party.remove_actor(aid)
    rescue
    end
    begin
      $game_actors.instance_variable_get(:@data)[aid] = nil
    rescue
    end
    begin
      $data_actors[aid] = nil
    rescue
    end
    send_party_data(true)
  end

  def self.save_guard_begin
    return nil unless host? && @party_map && !@party_map.empty?
    ids = @party_map.collect { |pair| pair.split(":")[1].to_i }
    actors = (($game_party.instance_variable_get(:@actors) rescue []) || []).dup
    data = {}
    gd = $game_actors.instance_variable_get(:@data)
    ids.each { |id| data[id] = gd[id] }
    $game_party.instance_variable_set(:@actors, actors - ids)
    ids.each { |id| gd[id] = nil }
    { :ids => ids, :actors => actors, :data => data }
  end

  def self.save_guard_end(state)
    return unless state
    $game_party.instance_variable_set(:@actors, state[:actors])
    gd = $game_actors.instance_variable_get(:@data)
    state[:data].each { |id, a| gd[id] = a }
  end

  def self.prepare_battle_actors
    return unless battle_on?
    log("prep battle actors")
    @battle_cmds = {}
    ensure_guest_party
    @battle_ids = (@party_map || []).collect { |pair| pair.split(":")[1].to_i }
    @battle_map = (@party_map || []).dup
    emit("bmap|#{@battle_map.join(',')}") if live? && !@battle_map.empty?
  end

  def self.cleanup_battle_actors
    @battle_ids = []
    @battle_cmds = {}
    @battle_map = []
    @cleanup_pending = false
  end

  def self.battle_actor?(id)
    @battle_ids.include?(id)
  end

  def self.my_actor_id
    @my_actor
  end

  def self.menu_actor
    @menu_actor
  end

  def self.set_menu_actor(a)
    @menu_actor = a
  end

  def self.clear_menu_actor
    @menu_actor = nil
  end

  def self.battle_rng
    @battle_rng
  end

  def self.logic_rng
    @vis > 0 ? nil : @battle_rng
  end

  def self.visual
    v = @vis
    @vis = v + 1
    yield
  ensure
    @vis = v
  end

  def self.logic
    v = @vis
    @vis = 0
    yield
  ensure
    @vis = v
  end

  def self.turn_sig
    l = (($game_party.members rescue []) + ($game_troop.members rescue [])).collect do |b|
      "#{b.hp}/#{b.states.collect { |x| x.id }.join(',')}/#{b.instance_variable_get(:@buffs).inspect.delete(' ')}"
    end
    log("turn sig #{(BattleManager.input_battler.name rescue '-')} #{l.join(' ')}") if @cfg[:heartbeat] == "1"
  end

  def self.real_rand(n)
    Kernel.instance_method(:coop_orig_rand).bind(self).call(n)
  end

  def self.plan_ready?
    @plan_ready
  end

  def self.consume_plan
    @plan_ready = false
  end

  def self.sync_events
    p = $game_player
    return unless p
    return if @in_battle
    rows = []
    $game_map.events.each do |id, e|
      next if (e.x - p.x).abs > 24 || (e.y - p.y).abs > 20
      row = event_row(id, e)
      next if @ev_last[id] == row
      @ev_last[id] = row
      rows << row
    end
    emit("evb|#{$game_map.map_id}|#{rows.join(';')}") unless rows.empty?
  end

  def self.step_events
    return if @ev_t.empty?
    @ev_t.each do |id, t|
      e = ($game_map.events[id] rescue nil)
      next unless e
      next if t[:erased]
      ex = e.real_x
      ey = e.real_y
      dx = t[:x] - ex
      dy = t[:y] - ey
      d = Math.sqrt(dx * dx + dy * dy)
      if d > 0.001
        if d > 4 || d < 0.01
          ex = t[:x]
          ey = t[:y]
        else
          k = d * 0.35
          k = 0.02 if k < 0.02
          k = d if k > d
          ex += dx / d * k
          ey += dy / d * k
        end
        e.instance_variable_set(:@real_x, ex)
        e.instance_variable_set(:@real_y, ey)
        e.instance_variable_set(:@x, t[:x].round)
        e.instance_variable_set(:@y, t[:y].round)
      end
      apply_event_look(e, t)
    end
  end

  def self.end_msgs
    @end_msgs = true
    emit("bfinal|#{battle_state_blob}") if host? && live? && battle_on?
  end

  def self.battle_final(str)
    return unless guest? && SceneManager.scene.is_a?(Scene_Battle)
    up = ($game_troop.members rescue []).select { |e| e.alive? }
    apply_battle_state(str)
    up.each do |e|
      next unless e.dead?
      e.instance_variable_set(:@hp, 0)
      e.perform_collapse_effect
    end
  end

  def self.watch_message
    gm = $game_message
    return unless gm
    if @msg_open && !gm.visible
      @msg_open = false
      @last_msg = nil
      emit("msgclose|#{@id}|#{@page}")
    end
  end

  def self.guest_tick
    p = $game_player
    return unless p
    if @ev_gmap != $game_map.map_id
      @ev_gmap = $game_map.map_id
      @ev_t = {}
      @ev_walk = {}
      @display = nil
    end
    p.transparent = true
    p.followers.visible = false
    on_map = SceneManager.scene.is_a?(Scene_Map)
    if @pending && on_map
      map, px, py, dir = @pending
      if $game_map.map_id != map
        unless p.transfer?
          log "following host to map #{map}"
          p.reserve_transfer(map, px.round, py.round, dir)
        end
      else
        p.moveto(px.round, py.round)
      end
      @pending = nil
    end
    if on_map && !p.transfer? && @host_map > 0 && $game_map.map_id == @host_map && @arrived_map != @host_map
      @arrived_map = @host_map
      @ev_t = {}
      request_resync
    end
    pump_resync
    if @mine && !@mine_sent && @id >= 0
      @mine_sent = true
      emit("mine|#{@id}|#{@mine}")
    end
    if @cfg[:demo] == "chat" && @frame == 1000
      Chat.instance_variable_set(:@buf, @cfg[:demosay] || "hey, guest here")
      Chat.say
      log("focus_self #{focus_self.inspect}")
    end
    unless @pos_q.empty?
      @pos_q.shift while @pos_q.size > 4
      @display = @pos_q.shift
      @trail_leader.feed(@display[2] * 32.0, @display[3] * 32.0, @display[4])
    end
    if @display && on_map
      fx0 = $game_map.instance_variable_get(:@bmsp_fog_x)
      fy0 = $game_map.instance_variable_get(:@bmsp_fog_y)
      ox = $game_map.display_x
      oy = $game_map.display_y
      $game_map.set_display_pos(@display[0], @display[1])
      if fx0
        $game_map.instance_variable_set(:@bmsp_fog_x, fx0 + ($game_map.display_x - ox))
        $game_map.instance_variable_set(:@bmsp_fog_y, fy0 + ($game_map.display_y - oy))
      end
    end
    apply_fx if @fx_in && on_map
    apply_party_data(@pdata_later) if @pdata_later && on_map
    if @cfg[:demoheal] == "1" && @my_actor && on_map && (@dh = @dh.to_i + 1) == 500
      a = $game_actors[@my_actor]
      it = $data_items[1]
      w = $data_weapons.compact.find { |x| a.equippable?(x) }
      $game_party.gain_item(it, 2)
      $game_party.gain_item(w, 1)
      a.change_equip(0, w)
      lead = $game_party.members[0]
      Coop.send_use(it, [lead])
      $game_party.consume_item(it)
      log("demo guest used #{it.name} on #{lead.name}, equipped #{w.id}, bag1=#{$game_party.item_number(it)}")
    end
    if @cfg[:demochat] == "1" && (@dk = @dk.to_i + 1) == 300
      Chat.selftest
    end
    send_gear if @frame % 15 == 0 && !@in_battle
    step_events
  end

  def self.guest_boot
    slot = @cfg[:save].to_i
    loaded = false
    begin
      loaded = DataManager.load_game(slot - 1) if slot > 0
    rescue => e
      log "load failed #{e.class}: #{e.message}"
    end
    unless loaded
      begin
        DataManager.setup_new_game
        a = $game_party.members[0]
        a.change_class(@cfg[:class].to_i) if a && @cfg[:class].to_i > 0
      rescue => e
        log "new game failed #{e.class}: #{e.message}"
      end
    end
    load_char
    $game_player.transparent = true
    $game_player.followers.visible = false
    begin
      $game_map.autoplay
    rescue
    end
    SceneManager.goto(Scene_Map)
  end

  def self.char_path
    nm = "#{@cfg[:name]}__#{@cfg[:src]}".gsub(/[^0-9A-Za-z_\-]/, "_")
    File.join(@dir, "chars", nm + ".rvdata2")
  end

  def self.bag_of_party
    [$game_party.instance_variable_get(:@items).dup, $game_party.instance_variable_get(:@weapons).dup,
     $game_party.instance_variable_get(:@armors).dup]
  end

  def self.load_char
    a = ($game_party.members[0] rescue nil)
    return unless a
    path = char_path
    if File.exist?(path)
      begin
        act, bag = File.open(path, "rb") { |f| Marshal.load(f) }
        act.instance_variable_set(:@actor_id, a.actor_id)
        $game_actors.instance_variable_get(:@data)[a.actor_id] = act
        $game_party.instance_variable_set(:@items, bag[0])
        $game_party.instance_variable_set(:@weapons, bag[1])
        $game_party.instance_variable_set(:@armors, bag[2])
        a = act
        log "char file loaded lv=#{a.level}"
      rescue => e
        log "char file unreadable #{e.class}"
      end
    end
    @mine = [Marshal.dump([a, bag_of_party])].pack("m0")
    @mine_sent = false
  end

  def self.save_char(blob)
    act, bag = Marshal.load(blob.unpack("m").first)
    Dir.mkdir(File.join(@dir, "chars")) unless File.directory?(File.join(@dir, "chars"))
    File.open(char_path, "wb") { |f| Marshal.dump([act, bag], f) }
    @mine = blob
    $game_party.instance_variable_set(:@items, bag[0])
    $game_party.instance_variable_set(:@weapons, bag[1])
    $game_party.instance_variable_set(:@armors, bag[2])
    log "char saved lv=#{act.level}" if @cfg[:heartbeat] == "1"
  rescue => e
    log "char save failed #{e.class}: #{e.message}"
  end

  def self.send_chars
    return unless host? && live?
    (@party_map || []).each do |pair|
      pid, aid = pair.split(":").collect { |x| x.to_i }
      a = ($game_actors[aid] rescue nil)
      c = (@chars || {})[pid]
      next unless a && c
      emit("char|#{pid}|" + [Marshal.dump([a, c[1]])].pack("m0"))
    end
  end

  def self.slot_pid(aid)
    pair = (@party_map || []).find { |x| x.split(":")[1].to_i == aid }
    pair ? pair.split(":")[0].to_i : nil
  end

  def self.consume_for(actor, item)
    if host? && $game_party.in_battle
      pid = slot_pid(actor.actor_id)
      return nil unless pid
      c = (@chars || {})[pid]
      if c && item.is_a?(RPG::Item) && item.consumable
        n = c[1][0][item.id].to_i - 1
        if n > 0
          c[1][0][item.id] = n
        else
          c[1][0].delete(item.id)
        end
      end
      return true
    end
    return true if guest? && @in_battle && @my_actor && actor.actor_id != @my_actor
    nil
  end

  def self.bag_has(actor, item)
    return nil unless host? && $game_party.in_battle && item.is_a?(RPG::Item)
    pid = slot_pid(actor.actor_id)
    return nil unless pid
    c = (@chars || {})[pid]
    return nil unless c
    c[1][0][item.id].to_i > 0
  end

  def self.autoload_slot
    (@cfg && @cfg[:autoload]).to_i
  end

  def self.host_autoload
    if DataManager.load_game(autoload_slot - 1)
      $game_system.on_after_load
      SceneManager.goto(Scene_Map)
    end
  rescue => e
    log "autoload failed #{e.class}: #{e.message}"
  end

  def self.send_evfx(id, k, v)
    return unless host? && live? && !@in_battle
    emit("evfx|#{$game_map.map_id}|#{id}|#{k}|#{v}")
  end

  def self.send_event_gone(id)
    return unless host? && live? && !@in_battle
    emit("evgone|#{$game_map.map_id}|#{id}")
  end

  def self.flush_changes
    return unless host? && live?
    unless @sw_out.empty?
      rows = @sw_out.collect { |id, v| "#{id}:#{v}" }
      @sw_out = {}
      emit("swb|#{rows.join(',')}")
    end
    unless @var_out.empty?
      rows = @var_out.collect { |id, v| "#{id}:" + [Marshal.dump(v)].pack("m0") }
      @var_out = {}
      emit("varb|#{rows.join(',')}")
    end
    unless @ssw_out.empty?
      rows = @ssw_out.collect { |row, v| "#{row}:#{v}" }
      @ssw_out = {}
      emit("sswb|#{rows.join(',')}")
    end
  end

  def self.send_switch(id, value)
    return unless host? && live? && !@in_battle
    @sw_out[id.to_i] = value ? 1 : 0
  end

  def self.send_self_switch(key, value)
    return unless host? && live? && !@in_battle
    return unless key.is_a?(Array) && key.size >= 3
    @ssw_out["#{key[0]}:#{key[1]}:#{b64(key[2])}"] = value ? 1 : 0
  end

  def self.send_audio(kind, args)
    return unless host? && live?
    return if kind == "se" && (@in_battle || @hush.to_i > 0)
    if kind == "bgm"
      @bgm = args
    elsif kind == "bgmstop"
      @bgm = nil
    elsif kind == "bgs"
      @bgs = args
    elsif kind == "bgsstop"
      @bgs = nil
    end
    f = args.collect { |a| a.is_a?(String) ? b64(a) : a.to_s }
    emit("aud|#{kind}|#{f.join('|')}")
  end

  def self.bgm
    @bgm
  end

  def self.bgs
    @bgs
  end

  def self.hush
    @hush = @hush.to_i + 1
    yield
  ensure
    @hush -= 1
  end

  def self.send_variable(id, value)
    return unless host? && live? && !@in_battle
    @var_out[id.to_i] = value
  end

  def self.send_picture(kind, num, args)
    return unless host? && live?
    f = args.collect { |a| a.is_a?(String) ? b64(a) : a.to_s }
    emit("pic|#{@id}|#{kind}|#{num}|#{f.join('|')}")
  end

  def self.send_effect(kind, args)
    return unless host? && live?
    emit("#{kind}|#{@id}|#{args.collect { |a| a.to_s }.join('|')}")
  end
end

module Coop
  class Link
    def initialize(addr, port)
      @addr = addr
      @port = port
      @sock = nil
      @buf = "".force_encoding("ASCII-8BIT")
      @out = "".force_encoding("ASCII-8BIT")
      @rx = nil
    end

    def open?
      !@sock.nil?
    end

    def api
      return @api if @api
      a = {}
      a[:startup] = Win32API.new("ws2_32", "WSAStartup", "IP", "I")
      a[:socket]  = Win32API.new("ws2_32", "socket", "III", "I")
      a[:connect] = Win32API.new("ws2_32", "connect", "IPI", "I")
      a[:send]    = Win32API.new("ws2_32", "send", "IPII", "I")
      a[:recv]    = Win32API.new("ws2_32", "recv", "IPII", "I")
      a[:close]   = Win32API.new("ws2_32", "closesocket", "I", "I")
      a[:ioctl]   = Win32API.new("ws2_32", "ioctlsocket", "IIP", "I")
      a[:inet]    = Win32API.new("ws2_32", "inet_addr", "P", "I")
      a[:sockopt] = Win32API.new("ws2_32", "setsockopt", "IIIPI", "I")
      a[:lasterr] = Win32API.new("ws2_32", "WSAGetLastError", "", "I")
      @api = a
    end

    def open
      return true if @sock
      begin
        a = api
        buf = "\0" * 400
        a[:startup].call(0x202, buf)
        s = a[:socket].call(2, 1, 6)
        if s == -1 || s == 4294967295 || s == 0
          Coop.log "socket() failed"
          return false
        end
        ip = a[:inet].call(@addr)
        if ip == 4294967295 || ip == -1
          Coop.log "bad address #{@addr}"
          a[:close].call(s)
          return false
        end
        sa = [2, @port].pack("sn") + [ip].pack("V") + "\0" * 8
        if a[:connect].call(s, sa, 16) != 0
          Coop.log "connect() failed for #{@addr}:#{@port}"
          a[:close].call(s)
          return false
        end
        a[:ioctl].call(s, 0x8004667E, [1].pack("L"))
        a[:sockopt].call(s, 6, 1, [1].pack("L"), 4)
        @sock = s
        @buf = "".force_encoding("ASCII-8BIT")
        @out = "".force_encoding("ASCII-8BIT")
        true
      rescue => e
        Coop.log "link error #{e.class}: #{e.message}"
        false
      end
    end

    def close
      return unless @sock
      begin
        api[:close].call(@sock)
      rescue
      end
      @sock = nil
      @out = "".force_encoding("ASCII-8BIT")
    end

    def write(line)
      return unless @sock
      @out << (line + "\n").force_encoding("ASCII-8BIT")
      if @out.bytesize > 2097152
        Coop.log "send buffer overflow, dropping link"
        close
        return
      end
      flush_out
    rescue
      close
    end

    def flush_out
      return unless @sock
      return if @out.nil? || @out.empty?
      a = api
      guard = 0
      while !@out.empty? && guard < 64
        guard += 1
        n = a[:send].call(@sock, @out, @out.bytesize, 0)
        if n.nil? || n < 0 || n == 4294967295
          fatal_error?("send") ? close : nil
          return
        elsif n == 0
          close
          return
        end
        @out = @out[n, @out.bytesize - n] || "".force_encoding("ASCII-8BIT")
      end
    rescue
      close
    end

    def fatal_error?(what)
      err = (api[:lasterr].call rescue 10035)
      return false if err == 10035 || err == 0
      Coop.log "socket #{what} error #{err}"
      true
    end

    def poll
      out = []
      return out unless @sock
      flush_out
      return out unless @sock
      a = api
      @rx ||= ("\0" * 8192).force_encoding("ASCII-8BIT")
      loop do
        n = a[:recv].call(@sock, @rx, 8192, 0)
        if n.nil? || n < 0 || n == 4294967295
          close if fatal_error?("recv")
          break
        elsif n == 0
          Coop.log "link closed by peer"
          close
          break
        else
          @buf << @rx[0, n]
        end
      end
      while (i = @buf.index("\n"))
        out << @buf.slice!(0..i).chomp
      end
      out
    rescue
      close
      out
    end
  end

  class Trail
    def initialize
      @pts = []
      @head = nil
      @target = nil
    end

    def clear
      @pts.clear
      @head = nil
      @target = nil
    end

    def feed(px, py, dir = nil)
      @dir = dir if dir
      @target = [px, py]
      if @head.nil?
        @head = [px, py]
        @pts << @head
      end
    end

    def step(max)
      return unless @target && @head
      dx = @target[0] - @head[0]
      dy = @target[1] - @head[1]
      d = Math.sqrt(dx * dx + dy * dy)
      return if d < 0.05
      if d > 96
        @head = [@target[0], @target[1]]
        @pts << @head
        return
      end
      k = d > max ? max : d
      @head = [@head[0] + dx / d * k, @head[1] + dy / d * k]
      last = @pts[-1]
      if (last[0] - @head[0]).abs + (last[1] - @head[1]).abs > 0.4
        @pts << @head
        @pts.shift while @pts.size > 900
      end
    end

    def head
      @head
    end

    def sample(dist)
      return nil if @pts.empty?
      return @pts[0] if @pts.size < 2
      remain = dist.to_f
      i = @pts.size - 1
      while i > 0
        ax = @pts[i][0]
        ay = @pts[i][1]
        bx = @pts[i - 1][0]
        by = @pts[i - 1][1]
        dx = ax - bx
        dy = ay - by
        d = Math.sqrt(dx * dx + dy * dy)
        if d >= remain && d > 0.001
          t = remain / d
          return [ax + (bx - ax) * t, ay + (by - ay) * t]
        end
        remain -= d
        i -= 1
      end
      h = @pts[-1]
      dx = 0
      dy = -1
      case @dir
      when 2 then dy = -1
      when 4 then dx = 1
      when 6 then dx = -1
      when 8 then dy = 1
      end
      [h[0] + dx * remain, h[1] + dy * remain]
    end
  end

  class Ghost < Game_Character
    def initialize(gfx, idx)
      super()
      @character_name = gfx.to_s
      @character_index = idx.to_i
      @tile_id = 0
      @through = true
      @transparent = false
      @pattern = 1
      @walk = 0
      @real_x = 0.0
      @real_y = 0.0
      @x = 0
      @y = 0
    end

    def place(px, py)
      nx = px / 32.0
      ny = py / 32.0
      dx = nx - @real_x
      dy = ny - @real_y
      if dx.abs > 0.04 || dy.abs > 0.04
        if dx.abs > dy.abs
          @direction = dx > 0 ? 6 : 4
        else
          @direction = dy > 0 ? 2 : 8
        end
        @walk = (@walk + 1) % 24
        @pattern = (@walk / 6) % 4
        @pattern = 1 if @pattern == 3
      else
        @pattern = 1
        @walk = 0
      end
      @real_x = nx
      @real_y = ny
      @x = nx.round
      @y = ny.round
    end
  end

  class Box < Window_Base
    def initialize
      super(0, 0, Graphics.width, fitting_height(4))
      self.z = 300
      self.openness = 0
      self.visible = false
      @face = ["", 0]
      @page_id = 0
      @ending = false
      @tokens = []
      @shown = 0
      @nw = nil
      @nwn = ""
      @bg = 0
      @back = Sprite.new
      @back.bitmap = Bitmap.new(width, height)
      c1 = Color.new(0, 0, 0, 160)
      c2 = Color.new(0, 0, 0, 0)
      @back.bitmap.gradient_fill_rect(Rect.new(0, 0, width, 12), c2, c1, true)
      @back.bitmap.fill_rect(Rect.new(0, 12, width, height - 24), c1)
      @back.bitmap.gradient_fill_rect(Rect.new(0, height - 12, width, 12), c1, c2, true)
      @back.visible = false
      @back.z = z - 1
    end

    def speak(name)
      if name.to_s != @nwn && @nw
        @nw.dispose
        @nw = nil
      end
      @nwn = name.to_s
      return if @nwn.empty? || !defined?(Window_FaceName)
      @nw ||= Window_FaceName.new(@nwn, z + 10)
      @nw.x = @face[0].to_s.empty? ? 0 : 96 + 20
      @nw.y = y > 0 ? y - 16 : height - 16
      @nw.visible = true
      @nw.open
    end

    def make_tokens(text)
      t = text.to_s
      out = []
      i = 0
      while i < t.length
        c = t[i, 1]
        if c == "\e"
          rest = t[i + 1, t.length - i - 1].to_s
          m = rest.match(/\A([\$\.\|\^!><\{\}\\]|[A-Z]+)(\[\d+\])?/i)
          len = m ? m[0].length : 0
          out << t[i, len + 1]
          i += len + 1
          next
        end
        out << c
        i += 1
      end
      out
    end

    def feed(page, face, fi, bg, pos, text, choices, name = "")
      @page_id = page
      @face = [face, fi]
      @tokens = make_tokens(text)
      @shown = 0
      @ending = false
      pos = 2 if pos.to_i > 2
      pos = 0 if pos.to_i < 0
      self.y = pos.to_i * (Graphics.height - height) / 2
      @bg = bg.to_i
      self.opacity = @bg == 0 ? 255 : 0
      self.visible = true
      open
      refresh
      speak(name)
    end

    def fast(page)
      return if page.to_i != @page_id
      @shown = @tokens.size
      refresh
    end

    def finish(page)
      return if page.to_i != @page_id
      @ending = true
    end

    def update
      super
      @back.visible = visible && @bg == 1
      @back.y = y
      @back.opacity = openness
      @nw.update if @nw
      if @ending
        close
        @nw.close if @nw
        if openness == 0
          self.visible = false
          @ending = false
        end
        return
      end
      return unless visible
      if @shown < @tokens.size
        @shown += 1
        @shown += 1 while @shown < @tokens.size && @tokens[@shown - 1].to_s[0, 1] == "\e"
        refresh
      end
    end

    def refresh
      contents.clear
      x = 0
      if @face[0].to_s != ""
        draw_face(@face[0], @face[1], 0, 0, true)
        x = 104
      end
      shown = @shown > @tokens.size ? @tokens.size : @shown
      draw_text_ex(x, 0, @tokens[0, shown].join)
    end
  end
end

module Coop
  class WaitBox < Window_Base
    def initialize
      super(Graphics.width / 2 - 160, 8, 320, 60)
      self.z = 410
      self.visible = false
      self.openness = 0
    end

    def show_wait(text)
      self.visible = true
      open
      contents.clear
      draw_text(0, 0, width, 24, text, 1)
    end

    def hide_wait
      @closing = true
    end

    def update
      super
      if @closing
        if openness == 0
          self.visible = false
          @closing = false
        end
      end
    end
  end

  module Render
    @sprites = {}
    @bubs = {}
    @ghosts = {}
    @key = nil
    @box = nil
    @hud = nil
    @hud_life = 0
    @hud_text = ""

    def self.invalidate
      @key = nil
    end

    def self.talking?
      !@box.nil? && @box.visible
    end

    def self.box
      return @box if @box
      return nil unless $game_system
      @box = Box.new
      @box
    end

    def self.ids
      Coop.peers.keys.sort
    end

    def self.dist_for(pid, list)
      return 0 if pid == Coop.leader
      others = list - [Coop.leader]
      i = others.index(pid)
      return 0 if i.nil?
      34 + 26 * i
    end

    def self.dispose_all
      @dead_at = {}
      @sprites.each_value { |s| s.dispose rescue nil }
      @sprites = {}
      @ghosts = {}
    end

    def self.ensure_sprites
      scene = SceneManager.scene
      unless scene.is_a?(Scene_Map)
        @sprites.each_value { |s| s.visible = false }
        @bubs.each_value { |b| b[0].visible = false }
        return false
      end
      sp = scene.instance_variable_get(:@spriteset)
      return false unless sp
      list = ids
      key = [sp.object_id, list, list.collect { |p| "#{Coop.peers[p][:name]}|#{Coop.peers[p][:gfx]}|#{Coop.peers[p][:idx]}|#{Coop.peers[p][:col]}" }]
      if key != @key
        dispose_all
        @key = key
        vp = sp.instance_variable_get(:@viewport1)
        fallback = ($game_player.character_name rescue "").to_s
        list.each do |pid|
          next if pid == Coop.my_id && Coop.host?
          info = Coop.peers[pid]
          next unless info
          gfx = info[:gfx].to_s
          gfx = fallback if gfx.empty?
          next if gfx.empty?
          begin
            g = Ghost.new(gfx, info[:idx])
            @ghosts[pid] = g
            @sprites[pid] = Sprite_Character.new(vp, g)
          rescue => e
            Coop.log "sprite fail #{gfx}: #{e.message}"
          end
        end
      end
      true
    end

    def self.say(pid, text, col)
      old = @bubs.delete(pid)
      old[0].dispose if old
      tmp = Bitmap.new(1, 1)
      tmp.font.size = 15
      tmp.font.outline = true
      lines = Chat.wrap(tmp, "", text.to_s, 200)
      w = lines.collect { |l| tmp.text_size(l).width }.max.to_i + 20
      tmp.dispose
      h = lines.size * 17 + 8
      sp = Sprite.new
      sp.bitmap = Bitmap.new(w, h)
      sp.bitmap.fill_rect(0, 0, w, h, Color.new(0, 0, 0, 150))
      sp.bitmap.font.size = 15
      sp.bitmap.font.outline = true
      sp.bitmap.font.color = Coop.hexcol(col)
      lines.each_with_index { |l, i| sp.bitmap.draw_text(4, 4 + i * 17, w - 8, 17, l, 1) }
      sp.ox = w / 2
      sp.oy = h
      sp.z = 260
      sp.visible = false
      @bubs[pid] = [sp, 300]
    end

    def self.bubbles
      @bubs.keys.each do |pid|
        b = @bubs[pid]
        ch = @ghosts[pid] || (pid == Coop.my_id ? $game_player : nil)
        b[1] -= 1
        if b[1] <= 0
          b[0].dispose
          @bubs.delete(pid)
          next
        end
        b[0].visible = !ch.nil?
        next unless ch
        b[0].x = ch.screen_x
        b[0].y = ch.screen_y - 40
        b[0].opacity = b[1] < 30 ? b[1] * 255 / 30 : 255
      end
    end

    def self.wait_show(text)
      return unless Coop.host?
      w = wait_box
      w.show_wait(text) if w
    end

    def self.wait_hide
      w = wait_box
      w.hide_wait if w
    end

    def self.wait_box
      return @wait_box if @wait_box
      return nil unless $game_system
      @wait_box = WaitBox.new
      @wait_box
    end

    def self.battle_frame
      return unless Coop.host?
      w = @wait_box
      w.update if w && w.visible
    end

    def self.frame
      battle_frame
      @box.update if @box && @box.visible && !SceneManager.scene.is_a?(Scene_Map)
      return unless ensure_sprites
      Coop.trail_leader.step(9)
      list = ids
      up = list - Coop.downed
      @dead_at ||= {}
      list.each do |pid|
        next if pid == Coop.my_id && Coop.host?
        g = @ghosts[pid]
        next unless g
        dn = Coop.downed.include?(pid)
        p = Coop.trail_leader.sample(dist_for(pid, dn ? list : up))
        if !dn
          @dead_at.delete(pid)
          g.place(p[0], p[1]) if p
        elsif p && @dead_at[pid] != $game_map.map_id
          g.place(p[0], p[1])
          @dead_at[pid] = $game_map.map_id
        end
        sp = @sprites[pid]
        if sp
          sp.visible = true
          sp.opacity = dn ? 110 : 255
          sp.update
        end
      end
      bubbles
      @box.update if @box && @box.visible
    end

    def self.hud(text)
      @hud_text = text.to_s
      @hud_life = 300
      return unless @hud
      @hud.bitmap.clear
      @hud.bitmap.fill_rect(0, 0, 420, 30, Color.new(0, 0, 0, 150))
      @hud.bitmap.font.size = 16
      @hud.bitmap.font.color = Color.new(240, 240, 245)
      @hud.bitmap.draw_text(10, 0, 400, 30, "co-op: #{@hud_text}", 0)
      @hud.opacity = 255
    end

    def self.hud_frame
      return unless Coop.guest?
      if @hud.nil? && $game_system
        @hud = Sprite.new
        @hud.bitmap = Bitmap.new(420, 30)
        @hud.z = 400
        @hud.opacity = 0
        hud(@hud_text) unless @hud_text.empty?
      end
      return unless @hud
      if @hud_life > 0
        @hud_life -= 1
        @hud.opacity = @hud_life > 0 ? 255 : 0
      end
    end

    def self.apply_picture(parts)
      kind = parts[2]
      num = parts[3].to_i
      p = $game_map.screen.pictures[num]
      case kind
      when "show"
        p.show(Coop.unb64(parts[4]), parts[5].to_i, parts[6].to_f, parts[7].to_f,
               parts[8].to_f, parts[9].to_f, parts[10].to_f, parts[11].to_i)
      when "move"
        p.move(parts[4].to_i, parts[5].to_f, parts[6].to_f, parts[7].to_f, parts[8].to_f,
               parts[9].to_f, parts[10].to_i, parts[11].to_i)
      when "rot"
        p.rotate(parts[4].to_i)
      when "angle"
        p.instance_variable_set(:@angle, parts[4].to_f)
      when "tint"
        p.start_tone_change(Tone.new(parts[4].to_i, parts[5].to_i, parts[6].to_i, parts[7].to_i), parts[8].to_i)
      when "erase"
        p.erase
      end
    end

    def self.apply_tone(parts)
      $game_map.screen.start_tone_change(Tone.new(parts[2].to_i, parts[3].to_i, parts[4].to_i, parts[5].to_i), parts[6].to_i)
    end

    def self.apply_flash(parts)
      $game_map.screen.start_flash(Color.new(parts[2].to_i, parts[3].to_i, parts[4].to_i, parts[5].to_i), parts[6].to_i)
    end

    def self.apply_audio(parts)
      kind = parts[1]
      a = parts[2..-1] || []
      case kind
      when "bgm"
        Audio.bgm_play(Coop.unb64(a[0]), a[1].to_i, a[2].to_i)
      when "bgmstop"
        Audio.bgm_stop
      when "bgmfade"
        Audio.bgm_fade(a[0].to_i)
      when "me"
        Audio.me_play(Coop.unb64(a[0]), a[1].to_i, a[2].to_i)
      when "mestop"
        Audio.me_stop
      when "se"
        Audio.se_play(Coop.unb64(a[0]), a[1].to_i, a[2].to_i)
      when "bgs"
        Audio.bgs_play(Coop.unb64(a[0]), a[1].to_i, a[2].to_i)
      when "bgsstop"
        Audio.bgs_stop
      when "bgsfade"
        Audio.bgs_fade(a[0].to_i)
      end
    end

    def self.apply_weather(parts)
      $game_map.screen.change_weather(parts[2].to_sym, parts[3].to_f, parts[4].to_i)
    end

    def self.apply_shake(parts)
      $game_map.screen.start_shake(parts[2].to_i, parts[3].to_i, parts[4].to_i)
    end

    def self.pictures_snapshot
      return unless Coop.host?
      return if ($game_map.map_id.to_i rescue 0) <= 0
      active = []
      $game_map.screen.pictures.each do |p|
        next if p.name.to_s.empty?
        active << p.number
      end
      Coop.emit("picset|#{active.join(',')}")
      $game_map.screen.pictures.each do |p|
        next if p.name.to_s.empty?
        Coop.send_picture("show", p.number, [p.name, p.origin, p.x, p.y, p.zoom_x, p.zoom_y, p.opacity, p.blend_type])
        t = p.tone
        if t.red.abs + t.green.abs + t.blue.abs + t.gray.abs > 1
          Coop.send_picture("tint", p.number, [t.red, t.green, t.blue, t.gray, 0])
        end
        dur = p.instance_variable_get(:@duration).to_i
        if dur > 0
          Coop.send_picture("move", p.number, [p.origin, p.instance_variable_get(:@target_x), p.instance_variable_get(:@target_y),
                                               p.instance_variable_get(:@target_zoom_x), p.instance_variable_get(:@target_zoom_y),
                                               p.instance_variable_get(:@target_opacity), p.blend_type, dur])
        end
        tdur = p.instance_variable_get(:@tone_duration).to_i
        tt = p.instance_variable_get(:@tone_target)
        if tdur > 0 && tt
          Coop.send_picture("tint", p.number, [tt.red, tt.green, tt.blue, tt.gray, tdur])
        end
        sp = p.instance_variable_get(:@rotate_speed).to_i
        Coop.send_picture("rot", p.number, [sp]) if sp != 0
        p_angle = p.angle.to_f
        Coop.send_picture("angle", p.number, [p_angle]) if p_angle != 0
      end
    end

    def self.apply_picture_set(parts)
      keep = (parts[1] || "").split(",").collect { |x| x.to_i }
      $game_map.screen.pictures.each do |p|
        next if p.name.to_s.empty?
        p.erase unless keep.include?(p.number)
      end
    end

    def self.effects_snapshot
      return unless Coop.host?
      scr = $game_map.screen
      if scr.weather_type != :none
        Coop.send_effect("weather", [scr.weather_type.to_s, scr.weather_power, 0])
      end
      if Coop.bgm
        Coop.send_audio("bgm", Coop.bgm)
      end
      if Coop.bgs
        Coop.send_audio("bgs", Coop.bgs)
      end
      t = scr.tone
      if t.red.abs + t.green.abs + t.blue.abs + t.gray.abs > 1
        Coop.send_effect("tone", [t.red, t.green, t.blue, t.gray, 0])
      end
    end
  end
end

module Coop
  module Chat
    @log = []
    @open = false
    @mute = false
    @buf = ""
    @prev = nil
    @rep = {}
    @tdown = false
    @blink = 0
    @dirty = true
    @spr = nil

    def self.api
      @api ||= {
        :ks => Win32API.new("user32", "GetKeyboardState", "P", "I"),
        :as => Win32API.new("user32", "GetAsyncKeyState", "I", "I"),
        :tu => Win32API.new("user32", "ToUnicode", "IIPPII", "I"),
        :mv => Win32API.new("user32", "MapVirtualKey", "II", "I"),
        :oc => Win32API.new("user32", "OpenClipboard", "I", "I"),
        :cc => Win32API.new("user32", "CloseClipboard", "", "I"),
        :ec => Win32API.new("user32", "EmptyClipboard", "", "I"),
        :gc => Win32API.new("user32", "GetClipboardData", "I", "I"),
        :sc => Win32API.new("user32", "SetClipboardData", "II", "I"),
        :ga => Win32API.new("kernel32", "GlobalAlloc", "II", "I"),
        :gl => Win32API.new("kernel32", "GlobalLock", "I", "I"),
        :gu => Win32API.new("kernel32", "GlobalUnlock", "I", "I"),
        :ln => Win32API.new("kernel32", "lstrlenW", "I", "I"),
        :rd => Win32API.new("kernel32", "RtlMoveMemory", "PII", "V"),
        :wr => Win32API.new("kernel32", "RtlMoveMemory", "IPI", "V")
      }
    end

    def self.open?
      @open || @mute
    end

    def self.down?(vk)
      (api[:as].call(vk) & 0x8000) != 0
    end

    def self.add(n, c, t)
      @log << [n.to_s, c.to_s, t.to_s, 600, nil]
      @log.shift while @log.size > 30
      @dirty = true
    end

    def self.update
      return unless $game_system
      if @spr.nil? || @spr.disposed?
        @spr = Sprite.new
        @spr.bitmap = Bitmap.new(360, 190)
        @spr.x = 8
        @spr.y = Graphics.height - 190 - 64
        @spr.z = 600
        @dirty = true
      end
      if @mute && ![0x0D, 0x1B, 0x54].any? { |k| down?(k) }
        @mute = false
      end
      td = down?(0x54)
      if @open
        typing
      elsif !@mute && td && !@tdown && Coop.live? && Coop.focused_input?
        @open = true
        @buf = ""
        @cur = 0
        @sel = nil
        @prev = nil
        @dirty = true
      end
      @tdown = td
      draw
    end

    def self.typing
      st = ("\0" * 256).force_encoding("ASCII-8BIT")
      api[:ks].call(st)
      pv = @prev || st
      @prev = st
      return unless Coop.focused_input?
      (8..0xfe).each do |vk|
        dn = st.getbyte(vk) & 0x80 != 0
        was = pv.getbyte(vk) & 0x80 != 0
        if dn && !was
          @rep[vk] = 0
          key(vk, st)
          return unless @open
        elsif dn && [0x08, 0x2E, 0x25, 0x27].include?(vk)
          r = @rep[vk].to_i + 1
          @rep[vk] = r
          key(vk, st) if r > 24 && r % 3 == 0
        end
      end
    end

    def self.key(vk, st)
      ctl = st.getbyte(0x11) & 0x80 != 0
      alt = st.getbyte(0x12) & 0x80 != 0
      sh = st.getbyte(0x10) & 0x80 != 0
      @cur = [[@cur.to_i, 0].max, @buf.length].min
      @dirty = true
      case vk
      when 0x0D then say
      when 0x1B then shut
      when 0x08
        return cut_sel if @sel
        go(ctl ? word(-1) : @cur - 1, true)
        cut_sel
      when 0x2E
        return cut_sel if @sel
        go(ctl ? word(1) : @cur + 1, true)
        cut_sel
      when 0x25 then go(ctl ? word(-1) : (@sel && !sh ? sel_range.first : @cur - 1), sh)
      when 0x27 then go(ctl ? word(1) : (@sel && !sh ? sel_range.last : @cur + 1), sh)
      when 0x24 then go(0, sh)
      when 0x23 then go(@buf.length, sh)
      else
        if ctl && !alt
          case vk
          when 0x41
            @sel = 0
            @cur = @buf.length
          when 0x43 then clip_set(sel_text) if @sel
          when 0x58
            if @sel
              clip_set(sel_text)
              cut_sel
            end
          when 0x56 then put(clip_get)
          end
          return
        end
        out = ("\0" * 16).force_encoding("ASCII-8BIT")
        n = api[:tu].call(vk, api[:mv].call(vk, 0), st, out, 8, 0)
        return if n <= 0
        put((out[0, n * 2].force_encoding("UTF-16LE").encode("UTF-8") rescue ""))
      end
    end

    def self.selftest
      old = clip_get
      st = ("\0" * 256).force_encoding("ASCII-8BIT")
      cs = st.dup
      cs.setbyte(0x11, 0x80)
      ss = st.dup
      ss.setbyte(0x10, 0x80)
      @open = true
      @buf = "hello big world"
      @cur = @buf.length
      @sel = nil
      key(0x25, cs)
      r1 = @cur
      key(0x25, cs)
      r2 = @cur
      key(0x27, cs)
      r3 = @cur
      key(0x08, cs)
      r4 = @buf.dup
      key(0x41, cs)
      key(0x43, cs)
      r5 = clip_get
      clip_set("PASTE ")
      key(0x24, st)
      key(0x56, cs)
      r6 = @buf.dup
      key(0x27, ss)
      key(0x27, ss)
      r7 = sel_text
      clip_set(old)
      Coop.log("chat selftest #{[r1, r2, r3, r4, r5, r6, r7].inspect}")
      shut
    end

    def self.go(i, keep)
      i = [[i, 0].max, @buf.length].min
      if keep
        @sel ||= @cur
      else
        @sel = nil
      end
      @cur = i
      @sel = nil if @sel == @cur
    end

    def self.word(d)
      i = @cur
      if d < 0
        i -= 1 while i > 0 && @buf[i - 1] == " "
        i -= 1 while i > 0 && @buf[i - 1] != " "
      else
        i += 1 while i < @buf.length && @buf[i] != " "
        i += 1 while i < @buf.length && @buf[i] == " "
      end
      i
    end

    def self.sel_range
      @sel < @cur ? (@sel...@cur) : (@cur...@sel)
    end

    def self.sel_text
      @buf[sel_range].to_s
    end

    def self.cut_sel
      return unless @sel
      r = sel_range
      @buf = @buf[0, r.first].to_s + @buf[r.last..-1].to_s
      @cur = r.first
      @sel = nil
    end

    def self.put(t)
      t = t.to_s.gsub(/[\r\n\t]/, " ").gsub(/[\x00-\x1f\x7f]/, "")
      cut_sel
      t = t[0, [120 - @buf.length, 0].max]
      return if t.empty?
      @buf = @buf[0, @cur].to_s + t + @buf[@cur..-1].to_s
      @cur += t.length
    end

    def self.clip_get
      return "" if api[:oc].call(0) == 0
      begin
        h = api[:gc].call(13)
        return "" if h == 0
        ptr = api[:gl].call(h)
        return "" if ptr == 0
        n = api[:ln].call(ptr)
        buf = ("\0" * (n * 2)).force_encoding("ASCII-8BIT")
        api[:rd].call(buf, ptr, n * 2)
        api[:gu].call(h)
        buf.force_encoding("UTF-16LE").encode("UTF-8")
      ensure
        api[:cc].call
      end
    rescue
      ""
    end

    def self.clip_set(t)
      w = (t.to_s.encode("UTF-16LE") + "\0".encode("UTF-16LE")).force_encoding("ASCII-8BIT")
      return if api[:oc].call(0) == 0
      begin
        api[:ec].call
        h = api[:ga].call(2, w.bytesize)
        ptr = api[:gl].call(h)
        api[:wr].call(ptr, w, w.bytesize)
        api[:gu].call(h)
        api[:sc].call(13, h)
      ensure
        api[:cc].call
      end
    rescue
      nil
    end

    def self.shut
      @open = false
      @mute = true
      @buf = ""
      @dirty = true
    end

    def self.say
      t = @buf.strip
      shut
      return if t.empty?
      n = Coop.profile[0].to_s
      n = "?" if n.empty?
      add(n, Coop.ncol, t)
      Render.say(Coop.my_id, t, Coop.ncol)
      Coop.emit("chat|#{Coop.my_id}|#{Coop.b64(n)}|#{Coop.ncol}|#{Coop.b64(t)}")
    end

    def self.wrap(b, pre, t, w)
      out = []
      cur = ""
      cw = b.text_size(pre).width
      t.scan(/\S+\s*/).each do |tok|
        if !cur.empty? && cw + b.text_size(cur + tok.rstrip).width > w
          out << cur.rstrip
          cur = ""
          cw = 0
        end
        if cw + b.text_size(cur + tok.rstrip).width > w
          tok.each_char do |ch|
            if !cur.empty? && cw + b.text_size(cur + ch).width > w
              out << cur
              cur = ""
              cw = 0
            end
            cur << ch
          end
        else
          cur << tok
        end
      end
      out << cur.rstrip
      out
    end

    def self.draw
      @blink += 1
      fade = false
      unless @open
        @log.each do |m|
          next if m[3] <= 0
          m[3] -= 1
          fade = true
        end
      end
      return unless @dirty || fade || (@open && @blink % 20 == 0)
      @dirty = false
      b = @spr.bitmap
      b.clear
      b.font.size = 16
      b.font.bold = false
      b.font.outline = true
      lh = 18
      rows = []
      list = @open ? @log.last(8) : @log.select { |m| m[3] > 0 }.last(6)
      list.each do |m|
        m[4] ||= wrap(b, m[0] + ": ", m[2], b.width - 12)
        m[4].each_with_index { |ln, i| rows << [m, ln, i == 0] }
      end
      rows = rows.last(@open ? 8 : 6)
      y = b.height - 26 - rows.size * lh
      b.fill_rect(0, y - 3, b.width, rows.size * lh + 3, Color.new(0, 0, 0, 110)) if @open && !rows.empty?
      rows.each do |m, ln, first|
        a = @open ? 255 : [m[3] * 255 / 60, 255].min
        b.font.out_color = Color.new(0, 0, 0, a * 3 / 4)
        x = 6
        if first
          b.font.color = Coop.hexcol(m[1], a)
          b.draw_text(x, y, b.width, lh, m[0])
          x += b.text_size(m[0]).width
          b.font.color = Color.new(235, 235, 245, a)
          b.draw_text(x, y, b.width, lh, ": ")
          x += b.text_size(": ").width
        end
        b.font.color = Color.new(235, 235, 245, a)
        b.draw_text(x, y, b.width - x, lh, ln)
        y += lh
      end
      return unless @open
      iy = b.height - 22
      b.fill_rect(0, iy, b.width, 22, Color.new(0, 0, 0, 170))
      b.font.color = Color.new(255, 255, 255)
      b.font.out_color = Color.new(0, 0, 0, 190)
      px = 6 + b.text_size("Say: ").width
      b.draw_text(6, iy, 60, 22, "Say: ")
      room = b.width - px - 8
      cur = [[@cur.to_i, 0].max, @buf.length].min
      @view = [[@view.to_i, cur].min, @buf.length].min
      @view += 1 while @view < cur && b.text_size(@buf[@view...cur]).width > room
      shown = @buf[@view..-1].to_s
      shown = shown[0...-1] while !shown.empty? && b.text_size(shown).width > room
      if @sel
        r = sel_range
        a0 = [[r.first - @view, 0].max, shown.length].min
        a1 = [[r.last - @view, 0].max, shown.length].min
        x0 = px + b.text_size(shown[0, a0]).width
        x1 = px + b.text_size(shown[0, a1]).width
        b.fill_rect(x0, iy + 3, x1 - x0, 16, Color.new(80, 120, 200, 200)) if x1 > x0
      end
      b.draw_text(px, iy, room + 4, 22, shown)
      cx = px + b.text_size(shown[0, cur - @view].to_s).width
      b.fill_rect(cx, iy + 4, 1, 14, Color.new(255, 255, 255)) if @blink / 20 % 2 == 0
    end
  end
end

module Input
  class << self
    [:trigger?, :press?, :repeat?, :dir4, :dir8].each do |m|
      alias_method("coop_#{m}", m)
    end

    def trigger?(sym)
      return true if sym == :C && Coop.cfg[:demoauto] == "1" && $game_message.busy? && Graphics.frame_count % 40 == 0
      Coop.input_ok? ? coop_trigger?(sym) : false
    end

    def press?(sym)
      Coop.input_ok? ? coop_press?(sym) : false
    end

    def repeat?(sym)
      Coop.input_ok? ? coop_repeat?(sym) : false
    end

    def dir4
      Coop.input_ok? ? coop_dir4 : 0
    end

    def dir8
      Coop.input_ok? ? coop_dir8 : 0
    end
  end
end

module Graphics
  class << self
    alias coop_update update
    def update
      Coop.logic { Coop.tick }
      coop_update
    end
  end
end

class Scene_Battle
  [:command_attack, :command_skill, :command_guard, :command_item,
   :on_enemy_ok, :on_actor_ok, :on_skill_ok, :on_item_ok].each do |name|
    alias_method("coop_cmd_#{name}", name)
    define_method(name) do |*args|
      begin
        if BattleManager.actor.nil? && Coop.my_actor_id
          ga = ($game_actors[Coop.my_actor_id] rescue nil)
          idx = ga ? $game_party.members.index(ga) : nil
          BattleManager.instance_variable_set(:@actor_index, idx) if idx
        end
      rescue
      end
      if BattleManager.actor.nil?
        Coop.log("nil actor on #{name} idx=#{BattleManager.instance_variable_get(:@actor_index).inspect} " +
                 "ib=#{(BattleManager.input_battler.name rescue '-')} wait=#{@coop_wait.inspect} pw=#{@coop_plan_wait.inspect}")
      end
      send("coop_cmd_#{name}", *args)
    end
  end
end

class Window_Message
  alias coop_update_show_fast update_show_fast
  def update_show_fast
    coop_update_show_fast
    if @show_fast && !@coop_fs && Coop.host?
      @coop_fs = true
      Coop.note_fast
    end
  end

  alias coop_new_page new_page
  def new_page(text, pos)
    @coop_fs = false
    coop_new_page(text, pos)
    Coop.note_page(text, self) if Coop.host?
  end
end

module BattleManager
  class << self
    alias coop_actor actor
    def actor
      a = coop_actor
      return a if a
      m = Coop.menu_actor
      return m if m
      if Coop.battle_on? && Coop.guest? && Coop.my_actor_id
        ga = ($game_actors[Coop.my_actor_id] rescue nil)
        if ga && $game_party.members.index(ga)
          return ga
        end
      end
      a
    end

    alias coop_setup setup
    def setup(troop_id, can_escape = true, can_lose = false)
      Coop.prepare_battle_actors
      coop_setup(troop_id, can_escape, can_lose)
    end
  end
end

class Game_Enemy
  def hp=(v)
    v = 1 if @coop_imm && v < 1
    super
  end

  def state_addable?(id)
    return false if @coop_imm && id == death_state_id
    super
  end
end

class Game_Actor
  def actor_id
    @actor_id
  end

  alias coop_mtimes make_action_times
  def make_action_times
    Coop.guest? && Coop.cfg[:demoplus] == "1" && actor_id == Coop.my_actor_id ? 2 : coop_mtimes
  end

  def consume_item(item)
    super unless Coop.consume_for(self, item)
  end

  def item_conditions_met?(item)
    ok = Coop.bag_has(self, item)
    ok.nil? ? super : (usable_item_conditions_met?(item) && ok)
  end

  alias coop_hprate hp_rate
  def hp_rate
    mhp > 0 ? coop_hprate : 0
  end

  alias coop_hpset hp=
  def hp=(v)
    coop_hpset(Coop.keep_dead?(self) ? 0 : v)
  end

  alias coop_rmstate remove_state
  def remove_state(id)
    coop_rmstate(id) unless id == death_state_id && Coop.keep_dead?(self)
  end

  alias coop_recover recover_all
  def recover_all
    coop_recover unless Coop.keep_dead?(self)
  end

  alias coop_iapply item_apply
  def item_apply(user, item)
    Coop.revive_ok { coop_iapply(user, item) }
  end

  alias coop_addstate add_state
  def add_state(id)
    Coop.revive_ok { coop_addstate(id) }
  end
end

class Scene_Battle
  alias coop_start start
  def start
    if Coop.battle_on? && ($game_temp.battle_equip rescue false)
      coop_start
      if Coop.guest?
        @coop_force_menu = true
        Coop.send_gear
      end
      return
    end
    @coop_chose = false
    if Coop.battle_on?
      if Coop.host?
        Coop.battle_scene_begin
      elsif Coop.guest?
        Coop.install_seed
      end
    end
    coop_start
    @coop_freeze = true if Coop.guest? && Coop.battle_on?
  end

  alias coop_start_actor_command_selection start_actor_command_selection
  def start_actor_command_selection
    return coop_start_actor_command_selection unless Coop.battle_on?
    a = BattleManager.actor
    ib = (BattleManager.input_battler rescue nil)
    live = a.is_a?(Game_Actor) && a.equal?(ib)
    if Coop.host? && live && a.is_a?(Game_Actor) && !Coop.battle_actor?(a.actor_id)
      Coop.emit("bfreeze|1")
    end
    if Coop.guest?
      if Coop.my_actor_id == a.actor_id && (@coop_force_menu || @coop_chose)
        @coop_force_menu = false
        @coop_chose = true
        Coop.log("guest menu #{a.name} slot #{a.action_input_index}")
        coop_start_actor_command_selection
        if Coop.cfg[:demoequip] == "1" && !@demo_eq
          @demo_eq = true
          command_equip_change
          return
        end
        if Coop.cfg[:demopick] == "1"
          a.input.set_guard
          next_command
        end
      elsif a
        @status_window.select(a.index) if @status_window && a.respond_to?(:index)
        a.input.set_attack if a.respond_to?(:input) && a.input
        next_command
      end
      return
    end
    if a.is_a?(Game_Actor) && (Coop.battle_actor?(a.actor_id) || Coop.cfg[:demoauto] == "1")
      a.input.set_attack if a.respond_to?(:input) && a.input
      next_command
      return
    end
    coop_start_actor_command_selection
  end

  alias coop_turn_start turn_start
  def turn_start
    unless Coop.battle_on?
      coop_turn_start
      return
    end
    if Coop.host?
      Coop.battle_collect_begin(self)
      return
    elsif Coop.guest?
      Coop.battle_guest_input if @coop_chose
      @coop_chose = false
      Coop.clear_menu_actor
      if Coop.plan_ready?
        Coop.apply_next_plan
        @coop_freeze = false
      else
        @coop_plan_wait = true
        return
      end
    end
    coop_turn_start
  end

  def force_guest_turn
    a = (($game_actors[Coop.my_actor_id] rescue nil))
    return unless a
    idx = $game_party.members.index(a)
    Coop.log("force guest turn #{a.name} idx=#{idx.inspect}")
    return unless idx
    BattleManager.instance_variable_set(:@actor_index, idx)
    BattleManager.instance_variable_set(:@input_battler, a) rescue nil
    @status_window.select(a.index) if @status_window && a.respond_to?(:index)
    @coop_chose = false
    @coop_force_menu = true
    a.instance_variable_set(:@action_input_index, 0)
    Coop.set_menu_actor(a)
    start_actor_command_selection
  end

  alias coop_ubasic update_basic
  def update_basic
    Coop.visual { coop_ubasic }
  end

  alias coop_turn_end turn_end
  def turn_end
    Coop.turn_sig if Coop.battle_on?
    coop_turn_end
    @coop_freeze = true if Coop.guest?
  end

  alias coop_show_fast? show_fast?
  def show_fast?
    if Coop.guest? && Coop.battle_on?
      f = Coop.remote_fast?
      $game_temp.battle_fastforward = f if $game_temp.respond_to?(:battle_fastforward=)
      return f
    end
    r = coop_show_fast?
    Coop.note_bfast(r) if Coop.host?
    r
  end

  alias coop_command_escape command_escape
  def command_escape
    return if Coop.guest?
    coop_command_escape
  end

  alias coop_update update
  def update
    unless Coop.battle_on?
      coop_update
      return
    end
    if Coop.guest? && Coop::Render.talking?
      [@status_window, @party_command_window, @actor_command_window].each { |w| w.close if w && !w.close? }
      @log_window.clear if @log_window && @log_window.line_number > 0
      @coop_hid = true
    elsif Coop.guest? && @coop_hid
      @coop_hid = false
      @status_window.open if @status_window
    end
    if @coop_leave
      @coop_leave = false
      @coop_plan_wait = false
      Coop.clear_menu_actor
      unless @coop_leaving || (scene_changing? rescue false)
        @coop_leaving = true
        SceneManager.return
      end
      return
    end
    if @coop_wait
      update_basic
      Coop.battle_host_poll(self, @coop_wait) if Coop.host?
      return
    end
    if @coop_plan_wait
      update_basic
      if Coop.guest? && Coop.plan_ready?
        Coop.apply_next_plan
        @coop_plan_wait = false
        @coop_freeze = false
        @actor_command_window.close if @actor_command_window && @actor_command_window.respond_to?(:close)
        coop_turn_start
      elsif Coop.guest? && @force_guest_turn
        @force_guest_turn = false
        @coop_plan_wait = false
        force_guest_turn
      end
      return
    end
    if Coop.guest? && @coop_freeze && !BattleManager.in_turn?
      update_basic
      if @force_guest_turn
        @force_guest_turn = false
        force_guest_turn
      end
      return
    end
    coop_update
  end
end

module BattleManager
  class << self
    alias coop_judge_win_loss judge_win_loss
    def judge_win_loss
      return coop_judge_win_loss unless Coop.battle_on?
      return false if Coop.guest?
      coop_judge_win_loss
    end

    alias coop_process_victory process_victory
    def process_victory
      return if Coop.battle_on? && Coop.guest?
      Coop.end_msgs
      coop_process_victory
    end

    alias coop_process_defeat process_defeat
    def process_defeat
      return if Coop.battle_on? && Coop.guest?
      Coop.end_msgs
      coop_process_defeat
    end
  end
end

module Audio
  class << self
    alias coop_bgm_play bgm_play
    def bgm_play(name, volume = 100, pitch = 100, pos = 0)
      Coop.send_audio("bgm", [name, volume, pitch])
      coop_bgm_play(name, volume, pitch, pos)
    end

    alias coop_bgm_stop bgm_stop
    def bgm_stop
      Coop.send_audio("bgmstop", [])
      coop_bgm_stop
    end

    alias coop_bgm_fade bgm_fade
    def bgm_fade(time)
      Coop.send_audio("bgmfade", [time])
      coop_bgm_fade(time)
    end

    alias coop_me_play me_play
    def me_play(name, volume = 100, pitch = 100)
      Coop.send_audio("me", [name, volume, pitch])
      coop_me_play(name, volume, pitch)
    end

    alias coop_me_stop me_stop
    def me_stop
      Coop.send_audio("mestop", [])
      coop_me_stop
    end

    alias coop_se_play se_play
    def se_play(name, volume = 100, pitch = 100)
      Coop.send_audio("se", [name, volume, pitch])
      coop_se_play(name, volume, pitch)
    end

    alias coop_bgs_play bgs_play
    def bgs_play(name, volume = 100, pitch = 100, pos = 0)
      Coop.send_audio("bgs", [name, volume, pitch])
      coop_bgs_play(name, volume, pitch, pos)
    end

    alias coop_bgs_stop bgs_stop
    def bgs_stop
      Coop.send_audio("bgsstop", [])
      coop_bgs_stop
    end

    alias coop_bgs_fade bgs_fade
    def bgs_fade(time)
      Coop.send_audio("bgsfade", [time])
      coop_bgs_fade(time)
    end
  end
end

module Sound
  class << self
    alias coop_play_system_sound play_system_sound
    def play_system_sound(n)
      Coop.hush { coop_play_system_sound(n) }
    end
  end
end

class Sprite_Base
  alias coop_animation_process_timing animation_process_timing
  def animation_process_timing(timing)
    Coop.hush { coop_animation_process_timing(timing) }
  end
end

class Game_Screen
  alias coop_weather change_weather
  def change_weather(type, power, duration)
    Coop.send_effect("weather", [type, power, duration])
    coop_weather(type, power, duration)
  end
end

class Game_SelfSwitches
  alias coop_set []=
  def []=(key, value)
    coop_set(key, value)
    Coop.send_self_switch(key, value) if Coop.host?
  end
end

class Game_Event
  alias coop_erase erase
  def erase
    Coop.send_event_gone(@id) if Coop.host?
    coop_erase
  end

  def animation_id=(v)
    @animation_id = v
    Coop.send_evfx(@id, "a", v) if Coop.host? && v.to_i > 0
  end

  def balloon_id=(v)
    @balloon_id = v
    Coop.send_evfx(@id, "b", v) if Coop.host? && v.to_i > 0
  end
end

class Game_Switches
  alias coop_set []=
  def []=(id, value)
    coop_set(id, value)
    Coop.send_switch(id, value) if Coop.host?
  end
end

class Game_Variables
  alias coop_set []=
  def []=(id, value)
    coop_set(id, value)
    Coop.send_variable(id, value) if Coop.host?
  end
end

class Game_Picture
  alias coop_show show
  def show(name, origin, x, y, zx, zy, op, blend)
    Coop.send_picture("show", @number, [name, origin, x, y, zx, zy, op, blend])
    coop_show(name, origin, x, y, zx, zy, op, blend)
  end

  alias coop_move move
  def move(origin, x, y, zx, zy, op, blend, duration)
    Coop.send_picture("move", @number, [origin, x, y, zx, zy, op, blend, duration])
    coop_move(origin, x, y, zx, zy, op, blend, duration)
  end

  alias coop_rotate rotate
  def rotate(speed)
    Coop.send_picture("rot", @number, [speed])
    coop_rotate(speed)
  end

  alias coop_tone start_tone_change
  def start_tone_change(tone, duration)
    Coop.send_picture("tint", @number, [tone.red, tone.green, tone.blue, tone.gray, duration])
    coop_tone(tone, duration)
  end

  alias coop_erase erase
  def erase
    Coop.send_picture("erase", @number, [])
    coop_erase
  end
end

class Game_Screen
  alias coop_tone start_tone_change
  def start_tone_change(tone, duration)
    Coop.send_effect("tone", [tone.red, tone.green, tone.blue, tone.gray, duration])
    coop_tone(tone, duration)
  end

  alias coop_flash start_flash
  def start_flash(color, duration)
    Coop.send_effect("flash", [color.red, color.green, color.blue, color.alpha, duration])
    coop_flash(color, duration)
  end

  alias coop_shake start_shake
  def start_shake(power, speed, duration)
    Coop.send_effect("shake", [power, speed, duration])
    coop_shake(power, speed, duration)
  end
end

class Game_Player
  alias coop_update update
  def update
    return if Coop.guest?
    coop_update
  end

  alias coop_refresh refresh
  def refresh
    coop_refresh
    look = Coop.host_look
    if look
      @character_name = look[0]
      @character_index = look[1]
    end
  end
end

class Game_Map
  alias coop_update update
  def update(main = false)
    if Coop.guest?
      refresh if @need_refresh
      update_scroll
      update_parallax
      bmsp_mapfog_update_fog if @bmsp_fog && respond_to?(:bmsp_mapfog_update_fog)
      @screen.update
      return
    end
    coop_update(main)
  end
end

if defined?(Window_KisekiStatus)
  class Window_KisekiStatus
    alias coop_update update
    def update
      coop_update
      self.visible = false if Coop.guest? && Coop::Render.talking?
    end
  end
end

if Game_Temp.method_defined?(:brain_noise=)
  class Game_Temp
    alias coop_brain_noise_set brain_noise=
    def brain_noise=(v)
      Coop.note_noise if v && !@brain_noise && Coop.host?
      coop_brain_noise_set(v)
    end
  end
end

class Game_Message
  alias coop_add add
  def add(text)
    coop_add(text) unless Coop.quiet_battle?
  end
end

class Game_Interpreter
  alias coop_c313 command_313
  def command_313
    Coop.revive_ok { coop_c313 }
  end

  alias coop_c314 command_314
  def command_314
    Coop.revive_ok { coop_c314 }
  end

  [:setup_choices, :setup_num_input, :setup_item_choice].each do |m|
    next unless method_defined?(m) || private_method_defined?(m)
    alias_method("coop_#{m}", m)
    define_method(m) do |*args|
      send("coop_#{m}", *args) unless Coop.quiet_battle?
    end
  end
end

class Scene_ItemBase
  alias coop_use_actors use_item_to_actors
  def use_item_to_actors
    Coop.send_use(item, item_target_actors) if Coop.guest? && Coop.live? && item.is_a?(RPG::Item)
    coop_use_actors
  end
end

class Spriteset_Map
  alias coop_dispose dispose
  def dispose
    Coop::Render.dispose_all
    coop_dispose
  end
end

class Scene_Map
  alias coop_update_encounter update_encounter
  def update_encounter
    return if Coop.guest?
    coop_update_encounter
  end

  alias coop_update_call_menu update_call_menu
  def update_call_menu
    coop_update_call_menu
  end
end

class Scene_Title
  alias coop_update update
  def update
    if Coop.guest? && !Coop.auto?
      Coop.mark_auto
      Coop.guest_boot
      return
    end
    if Coop.host? && !Coop.auto? && Coop.autoload_slot > 0
      Coop.mark_auto
      Coop.host_autoload
      return
    end
    coop_update
  end
end

module DataManager
  class << self
    alias coop_save_game save_game_without_rescue
    def save_game_without_rescue(index)
      state = Coop.save_guard_begin
      fs = Coop.face_guard_begin
      begin
        coop_save_game(index)
      ensure
        Coop.face_guard_end(fs)
        Coop.save_guard_end(state)
      end
    end

    alias coop_make_filename make_filename
    def make_filename(index)
      return coop_make_filename(index) unless Coop.guest?
      dir = File.join("coop", "saves")
      Dir.mkdir(dir) unless File.directory?(dir)
      sprintf(File.join(dir, "Save%02d.rvdata2"), index + 1)
    end

    alias coop_save_file_exists? save_file_exists?
    def save_file_exists?
      return coop_save_file_exists? unless Coop.guest?
      !Dir.glob("coop/saves/Save*.rvdata2").empty?
    end
  end
end

Coop.boot


class CoopRng
  def initialize(seed)
    @s = ((seed.to_i & 0x7fffffff) | 1)
  end

  def rand(*args)
    @s = (@s * 1103515245 + 12345) & 0x7fffffff
    v = @s.to_f / 2147483648.0
    return v if args.empty?
    a = args[0]
    if a.is_a?(Range)
      lo = a.first
      hi = a.last
      hi -= 1 if a.exclude_end?
      return lo + (v * (hi - lo + 1)).to_i
    end
    n = a.to_i
    return (v * n).to_i if n > 0
    v
  end
end

module Kernel
  alias coop_orig_rand rand
  def rand(*args)
    r = Coop.logic_rng
    if r
      r.rand(*args)
    else
      coop_orig_rand(*args)
    end
  end
end
