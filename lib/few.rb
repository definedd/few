File::NULL = '/dev/null' unless defined? File::NULL

class Few
  module Util # {{{
    def open_browser(url)
      case RUBY_PLATFORM.downcase
      when /linux/
        if ENV['KDE_FULL_SESSION'] == 'true'
          system 'kfmclient', 'exec', url
        elsif ENV['GNOME_DESKTOP_SESSION_ID']
          system 'gnome-open', url, :out => File::NULL, :err => File::NULL
        elsif system 'exo-open', '-v', :out => File::NULL, :err => File::NULL
          system 'exo-open', url
        else
          system 'firefox', url
        end
      when /darwin/
        system 'open', url
      when /mswin(?!ce)|mingw|bccwin/
        system 'start', url
      else
        system 'firefox', url
      end
    end

    def require_monad(*libraries)
      libraries.all? {|l|
        l = l.to_s
        begin
          if File.basename(l).include? '.'
            load l
          else
            require l
          end
        rescue LoadError
        end
      }
    end
  end # }}}

  class Config # {{{
    def initialize(i)
      @c = i
    end

    def method_missing(n, *a)
      case n.to_s
      when /=$/
        @c[n.to_s.gsub(/=$/, '').to_sym] = a[0]
      else
        @c[n]
      end
    end
  end # }}}

  class RemoteHelper # {{{
    def initialize(o = {})
      require 'net/http'
      require 'openssl'
      require 'uri'
      require 'cgi'
      @opt = {
        :private_key => nil, :public_key => nil, :remote_path => 'http://sorah.cosmio.net/few_server.rb'
      }.merge(o)
      @priv_key = @opt[:private_key] ?
        OpenSSL::PKey::RSA.new(@opt[:private_key]) : nil
      @publ_key = @opt[:public_key ] ?
        OpenSSL::PKey::RSA.new(@opt[:public_key ]) : nil
      @remote_path = @opt[:remote_path] ?
        URI.parse(@opt[:remote_path]) : nil
    end

    def generate_key_pair
      rsa                = OpenSSL::PKey::RSA.generate(2048)
      @opt[:private_key] = rsa.export
      @opt[:public_key ] = rsa.public_key.to_s
      @priv_key          = rsa
      @publ_key          = OpenSSL::PKey::RSA.new(rsa.public_key)
      self
    end

    def private_key;     @opt[:private_key]; end
    def public_key;      @opt[:public_key ]; end
    def remote_path;     @opt[:remote_path]; end
    def private_key=(x); @opt[:private_key]; @priv_key    = OpenSSL::PKey::RSA.new(@opt[:private_key]); x; end
    def public_key=(x);  @opt[:public_key ]; @publ_key    = OpenSSL::PKey::RSA.new(@opt[:public_key ]); x; end
    def remote_path=(x); @opt[:remote_path]; @remote_path = URI.parse(@opt[:remote_path             ]); x; end

    def crypt(str)
      r = OpenSSL::Cipher::AES.new("256-CBC")
      p = (1..32).map{(rand(95)+33).chr}.join
      r.encrypt
      r.pkcs5_keyivgen(p)
      c =  r.update(str)
      c << r.final
      begin
        [Base64.encode64(c),Base64.encode64(@publ_key.public_encrypt(p))]
      rescue NoMethodError
        return false
      end
    end

    def decrypt(str,key)
      r = OpenSSL::Cipher::AES.new("256-CBC")
      r.decrypt
      begin
        k = @priv_key.private_decrypt(Base64.decode64(key))
        r.pkcs5_keyivgen(k)
        s =  r.update(Base64.decode64(str))
        s << r.final
        return s
      rescue NoMethodError
        return false
      end
    end

    def send(str)
      return unless @opt[:remote_path]
      c = crypt(str)
      begin
        Net::HTTP.start(@remote_path.host, @remote_path.port) do |h|
          r = h.post(
            @remote_path.path,
            'public_key=' + CGI.escape(@opt[:public_key]) +
            '&body=' + CGI.escape(c[0]) + '&aes_key=' + CGI.escape(c[1]))
        end
      rescue Net::ProtocolError
        return r
      else
        return true
      end
    end

    def recv
      return unless @opt[:remote_path]
      Net::HTTP.start(@remote_path.host, @remote_path.port) do |h|
        r = h.get(
          @remote_path.path + '?public_key=' + CGI.escape(@opt[:public_key]))
        begin; b = r.body.split(/\r?\n/); rescue; return nil; end
        s = b.shift
        return nil if s.nil?
        if s.chomp == 'have'
          kb = b.join("\n").split(/\n\n--- \('\.v\.'\) < hi ---\n/)
          decrypt(*kb)
        else
          return nil
        end
      end
    end
  end # }}}

  def initialize(o={})
    @opt = {:filetype => :text, :tee => false, :server => false}.merge(o)
    @config = Few::Config.new(
      :remote => false, :private_key => fewdir('key'),
      :public_key => fewdir('key.pub'), :remote_path => 'http://priv2.soralabo.net/few_server.rb')
    load_config
    @remote = Few::RemoteHelper.new(
      :remote_path => @config.remote_path,
      :public_key  => @config.public_key.nil?  ? nil : (File.exist?(@config.public_key ) ? File.read(@config.public_key ) : nil),
      :private_key => @config.private_key.nil? ? nil : (File.exist?(@config.private_key) ? File.read(@config.private_key) : nil))
  end

  def start(daemonize=false)
    return self unless @opt[:remote_standing]
    abort 'ERROR: public_key or private_key not found. Try generate to this command: few --gen-keys' if @remote.public_key.nil? || @remote.private_key.nil?
    if daemonize
      puts 'Daemoning...'
      if Process.respond_to?(:daemon)
        Process.daemon
      else
        require 'webrick'
        WEBrick::Daemon.start
      end
    end
    puts "Started"
    loop do
      r = @remote.recv
      unless r.nil?
        puts "Received body"
        puts "Running..."
        run(r)
        puts "Opened browser"
        sleep 10
      else
        sleep 6
      end
    end
  end

  def load_config
    return if $few_speccing
    config_files =
      %w[_fewrc .fewrc .few.conf few.conf .fewrc.rb _fewrc.rb fewrc.rb]
    config_files.delete_if {|x| !File.exist?(File.expand_path("~") + '/' + x) }
    if config_files.length > 0
      config_file = config_files[0]
      eval File.read(File.expand_path('~') + '/' + config_file)
    end
    self
  end

  def init_ftdetects
    fewdirs('ftdetect') + fewdirs('ftdetect',true)
  end

  def fewdir(path,runtime=false)
    if $few_speccing || runtime
      return File.dirname(__FILE__) + '/../fewfiles/' + path
    else
      config_dirs = %w[.few fewfiles]
      config_dirs.delete_if{|x| !File.exist?(File.expand_path("~") + '/' + x)}
      if config_dirs.length > 0
        dir = File.expand_path("~") + '/' + config_dirs[0]
        dir+'/'+path
      else
        if /mswin(?!ce)|mingw|bccwin/ == RUBY_PLATFORM
          Dir.mkdir(File.expand_path('~') + '/fewfiles')
          return File.expand_path('~') + '/fewfiles/'+path
        else
          Dir.mkdir(File.expand_path('~') + '/.few')
          return File.expand_path('~') + '/.few/'+path
        end
      end
    end
  end

  def fewdirs(path,runtime=false)
    if File.exist?(fewdir(path,runtime)) && FileTest.directory?(fewdir(path,runtime))
      Dir.entries(fewdir(path,runtime))
    else; []
    end
  end

  def generate_remote_key_pair
    @remote.generate_key_pair
    open(@config.public_key ,'w') { |f| f.print @remote.public_key  }
    open(@config.private_key,'w') { |f| f.print @remote.private_key }
    self
  end

  def run(i = nil)
    if @config.remote && i.nil?
      if @opt[:tee]
        b = ''
        ARGF.each do |l|
          print l
          b += l
        end
        a = b
      else
        a = ARGF.read.toutf8
      end
      unless @remote.public_key
        abort "ERROR: public_key is not found. If you don't have keys, try to generate one with this command on host: few --gen-keys\n" +
          "  If you have keys, just move them to ~/.few"
      end
      unless (r = @remote.send(a)) == true
        abort "ERROR: #{r.inspect}"
      end
    else
      t = Tempfile.new('few')

      File.open(t.path, 'w') do |io|
        if i.nil?
          if @opt[:tee]
            b = ''
            ARGF.each do |l|
              print l
              b += l
            end
            a = CGI.escapeHTML b
          else
            a = CGI.escapeHTML ARGF.read.toutf8
          end
        else
          a = CGI.escapeHTML i
        end
        r = a
        a = a.gsub(/\r?\n/, "<br />\n")

        a = a.gsub(/.\x08/, '')
        a = a.gsub(/\x1b\[([0-9]*)m/) do
          case $1
          when "","39"
            '</font>'
          when "30"
            '<font color="black">'
          when "31"
            '<font color="red">'
          when "32"
            '<font color="green">'
          when "33"
            '<font color="yellow">'
          when "34"
            '<font color="blue">'
          when "35"
            '<font color="magenta">'
          when "36"
            '<font color="cyan">'
          when "37"
            '<font color="white">'
          else
            ''
          end
        end

        io.puts <<-EOF
<html>
  <head>
    <title>few: #{i.nil? ? ARGF.filename : '-'} (#{@opt[:filetype].to_s})</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
    <style type="text/css">
        body {
          font-family: Georgia, "menlo regular", "monaco", "courier", monospace;
        }
        .few_body {
          font-size: 12pt;
        }

        #{File.exist?(fewdir('style.css')) ? File.read(fewdir('style.css')) : ""}
    </style>
  </head>
  <body>
    <h1>few: #{i.nil? ? ARGF.filename : '-'} (#{@opt[:filetype].to_s})</h1>
    <div class="few_body">
#{a}
    </div>
    <textarea col="10" row="15">
#{r}
    </textarea>
  </body>
</html>
      EOF
      end

      t.close

      File.rename(t.path, html = t.path + '.html')

      open_browser(html)
    end

  end
  attr_reader :config
end

def Few(o = {})
  Few.new(o).run
end
