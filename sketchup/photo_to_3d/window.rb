# encoding: utf-8
require 'base64'

module PhotoTo3D
  # The Photo to 3D window: pick a photo, choose settings, watch progress.
  module Window
    MAX_DROP_BYTES = 30 * 1024 * 1024
    PHOTO_TYPES = %w[.jpg .jpeg .png .webp .bmp].freeze
    ENGINES = %w[hunyuan triposr meshy].freeze
    PREFS = 'PhotoTo3D'

    @dialog = nil
    @photo = nil
    RELEASES_API = 'https://api.github.com/repos/yiukwanwa/photo-to-3d/releases/latest'.freeze
    DOWNLOAD_PAGE = 'https://chilldim.site/'.freeze

    @settings = { engine: 'hunyuan', faces: 20000, colors: 32, remove_background: true, remove_lighting: true,
                  place: 'mouse' }
    @latest_version = nil

    def self.show
      @dialog ||= create_dialog
      @dialog.visible? ? @dialog.bring_to_front : @dialog.show
    end

    def self.create_dialog
      dialog = UI::HtmlDialog.new(
        dialog_title: '相片變3D',
        preferences_key: 'PhotoTo3D.Window',
        width: 440, height: 720, min_width: 380, min_height: 560,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dialog.set_file(File.join(PLUGIN_DIR, 'window.html'))
      on(dialog, 'ready') { send_init; check_for_update }
      on(dialog, 'choosePhoto') { choose_photo }
      on(dialog, 'droppedPhoto') { |name, data_url| dropped_photo(name, data_url) }
      on(dialog, 'make') { |settings| make(settings) }
      on(dialog, 'cancel') { PhotoTo3D.cancel_job; call('cancelled') }
      on(dialog, 'openFolder') { PhotoTo3D.open_work_folder }
      on(dialog, 'openLog') { |path| UI.openURL("file:///#{path}") }
      on(dialog, 'installAi') { PhotoTo3D.run_installer }
      on(dialog, 'recheck') { send_init }
      on(dialog, 'forgetKey') { Sketchup.write_default(PREFS, 'meshy_key', ''); send_init }
      on(dialog, 'openUrl') { |url| UI.openURL(url) if url.to_s.start_with?('https://') }
      on(dialog, 'getUpdate') { UI.openURL(DOWNLOAD_PAGE) }
      dialog
    end

    # Registers a callback from the window. A Ruby error shows in the window
    # (and the Ruby Console) instead of the button silently doing nothing.
    def self.on(dialog, name, &block)
      dialog.add_action_callback(name) do |_, *args|
        block.call(*args)
      rescue StandardError => error
        puts "相片變3D #{name}: #{error.full_message}"
        call('error', "相片變3D 出錯（#{name}）：#{error.message}")
      end
    end

    def self.send_init
      height = @settings[:height] || 1.m
      call('init', {
        installed: PhotoTo3D.installed?,
        busy: PhotoTo3D.busy?,
        photo: @photo,
        height: height.to_s,
        engine: @settings[:engine],
        faces: @settings[:faces],
        colors: @settings[:colors],
        removeBackground: @settings[:remove_background],
        removeLighting: @settings[:remove_lighting],
        place: @settings[:place],
        meshyKeySaved: !saved_key.empty?,
        version: VERSION,
        latestVersion: @latest_version
      })
    end

    # Asks GitHub once per SketchUp session whether a newer version is out.
    def self.check_for_update
      return if @update_request

      @update_request = Sketchup::Http::Request.new(RELEASES_API, Sketchup::Http::GET)
      @update_request.headers = { 'Accept' => 'application/vnd.github+json', 'User-Agent' => 'PhotoTo3D' }
      @update_request.start do |_, response|
        next unless response.status_code == 200

        latest = JSON.parse(response.body)['tag_name'].to_s.sub(/\Av/, '')
        if newer?(latest, VERSION)
          @latest_version = latest
          call('updateAvailable', latest)
        end
      rescue StandardError
        nil # no internet or GitHub is down: just don't show the notice
      end
    end

    def self.newer?(latest, current)
      parts = ->(version) { version.split('.').map(&:to_i) }
      latest.match?(/\A\d+(\.\d+)*\z/) && (parts.call(latest) <=> parts.call(current)) == 1
    end

    def self.saved_key
      Sketchup.read_default(PREFS, 'meshy_key', '').to_s
    end

    def self.choose_photo
      path = UI.openpanel('揀一張物件相', '', 'Photos|*.jpg;*.jpeg;*.png;*.webp;*.bmp||')
      set_photo(path.tr('\\', '/')) if path
    end

    # A photo dragged into the window arrives as file data, not a path, so save it.
    def self.dropped_photo(name, data_url)
      extension = File.extname(name.to_s).downcase
      return call('error', '請用 JPG、PNG、WEBP 或者 BMP 相。') unless PHOTO_TYPES.include?(extension)

      bytes = Base64.decode64(data_url.to_s.sub(/\Adata:[^,]*,/, ''))
      return call('error', '張相太大喇（超過 30 MB）。') if bytes.bytesize > MAX_DROP_BYTES

      folder = File.join(JOBS, 'photos')
      FileUtils.mkdir_p(folder)
      path = File.join(folder, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{File.basename(name).gsub(/[^\w.\-]/, '_')}")
      File.binwrite(path, bytes)
      set_photo(path)
    end

    def self.set_photo(path)
      @photo = path
      call('setPhoto', path)
    end

    def self.make(json)
      input = JSON.parse(json)
      height = begin
        input['height'].to_s.to_l
      rescue ArgumentError
        return call('error', "\"#{input['height']}\" 唔係 SketchUp 識嘅尺寸。試下 80cm 或者 2'。")
      end
      return call('error', '模型高度要大過 0。') if height <= 0
      return call('error', '請先揀相。') unless @photo && File.exist?(@photo)
      return call('error', '而家整緊另一個模型，請等等。') if PhotoTo3D.busy?

      engine = ENGINES.include?(input['engine']) ? input['engine'] : 'hunyuan'
      key = input['meshyKey'].to_s.strip
      key = saved_key if key.empty?
      return call('error', '用 Meshy 要先輸入你嘅 Meshy API key。') if engine == 'meshy' && key.empty?

      Sketchup.write_default(PREFS, 'meshy_key', key) if engine == 'meshy' && input['rememberKey']
      @settings = {
        engine: engine,
        height: height,
        faces: input['faces'].to_i.clamp(1000, 300_000),
        colors: input['colors'].to_i.clamp(1, 64),
        remove_background: input['removeBackground'] ? true : false,
        remove_lighting: input['removeLighting'] ? true : false,
        place: input['place'] == 'origin' ? 'origin' : 'mouse'
      }
      PhotoTo3D.start_job(@settings.merge(photo: @photo, meshy_key: key), self)
      call('started', height.to_s)
    end

    # Listener methods called by PhotoTo3D while a job runs.
    def self.progress(step, total, message, seconds)
      call('progress', { step: step, total: total, message: message, seconds: seconds })
    end

    def self.succeeded(faces, seconds, place)
      call('succeeded', { faces: faces, seconds: seconds, place: place })
    end

    def self.failed(reason, log)
      call('failed', { reason: reason, log: log })
      UI.messagebox("唔好意思，整唔到模型。\n\n#{reason}") unless @dialog&.visible?
    end

    def self.call(function, argument = nil)
      return unless @dialog&.visible?

      @dialog.execute_script("app.#{function}(#{JSON.generate(argument)})")
    end
  end
end
