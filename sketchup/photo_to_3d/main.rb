# encoding: utf-8
require 'sketchup.rb'
require 'json'
require 'fileutils'

module PhotoTo3D
  HOME = File.join(ENV['LOCALAPPDATA'].to_s.tr('\\', '/'), 'PhotoTo3D')
  PYTHON = File.join(HOME, 'venv', 'Scripts', 'pythonw.exe')
  JOBS = File.join(HOME, 'jobs')
  # install.ps1 writes this when the AI is fully installed; bump it when the AI setup changes.
  READY_FILE = File.join(HOME, 'ready-v2.txt')
  PLUGIN_DIR = File.dirname(__FILE__)
  SCRIPT = File.join(PLUGIN_DIR, 'backend', 'photo_to_3d.py')
  INSTALLER = File.join(PLUGIN_DIR, 'install.ps1')

  # SketchUp drops faces smaller than about 0.001", so small models are built
  # at least this tall and then scaled down on the instance.
  MIN_BUILD_HEIGHT = 10.m

  @job = nil

  def self.installed?
    File.exist?(PYTHON) && File.exist?(READY_FILE)
  end

  # Opens the installer in its own console window so the progress is visible.
  def self.run_installer
    Process.spawn('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                  '-File', INSTALLER.tr('/', '\\'), '-PauseAtEnd')
  end

  def self.busy?
    !@job.nil?
  end

  # Starts the AI in the background. `settings` keys: photo, engine, height
  # (Length), faces, colors, remove_background, remove_lighting, meshy_key. Progress, success
  # and failure are reported to `listener` (see Window).
  def self.start_job(settings, listener)
    job_dir = File.join(JOBS, Time.now.strftime('%Y%m%d-%H%M%S'))
    FileUtils.mkdir_p(job_dir)
    job = {
      out: File.join(job_dir, 'model.json'),
      status: File.join(job_dir, 'status.txt'),
      log: File.join(job_dir, 'log.txt'),
      name: File.basename(settings[:photo], '.*'),
      height: settings[:height],
      listener: listener,
      started: Time.now
    }

    command = [PYTHON, SCRIPT, '--image', settings[:photo], '--out', job[:out], '--status', job[:status],
               '--engine', settings[:engine], '--faces', settings[:faces].to_s, '--colors', settings[:colors].to_s]
    command << '--keep-background' unless settings[:remove_background]
    command << '--remove-lighting' if settings[:remove_lighting]
    # The API key goes in the environment so it never shows up in the command line or log.
    env = { 'PHOTOTO3D_MESHY_KEY' => settings[:engine] == 'meshy' ? settings[:meshy_key].to_s : '' }
    job[:pid] = Process.spawn(env, *command, [:out, :err] => [job[:log], 'w'])

    @job = job
    @timer = UI.start_timer(0.5, true) { poll }
  end

  def self.cancel_job
    return unless @job

    begin
      Process.kill('KILL', @job[:pid])
      Process.wait(@job[:pid])
    rescue StandardError
      nil
    end
    finish_job
  end

  def self.finish_job
    UI.stop_timer(@timer) if @timer
    @timer = nil
    @job = nil
    Sketchup.status_text = ''
  end

  def self.poll
    job = @job
    return unless job

    step, total, message = read_status(job)
    seconds = (Time.now - job[:started]).round
    Sketchup.status_text = "相片變3D：#{message}（#{seconds} 秒）"
    job[:listener].progress(step, total, message, seconds)

    finished = begin
      Process.wait(job[:pid], Process::WNOHANG)
    rescue Errno::ECHILD
      true
    end
    return unless finished

    finish_job
    if File.exist?(job[:out])
      Sketchup.status_text = '相片變3D：加入 SketchUp 緊...'
      faces = build(JSON.parse(File.read(job[:out], encoding: 'UTF-8')), job[:name], job[:height])
      job[:listener].succeeded(faces, seconds)
    else
      job[:listener].failed(failure_reason(job), job[:log])
    end
  rescue StandardError => error
    finish_job
    job[:listener].failed("模型加唔到入 SketchUp：#{error.message}", job[:log])
  end

  def self.read_status(job)
    return [0, 5, '開始緊...'] unless File.exist?(job[:status])

    step, total, message = File.read(job[:status], encoding: 'UTF-8').strip.split('|', 3)
    [step.to_i, total.to_i, message.to_s]
  rescue StandardError
    [0, 5, '處理緊...']
  end

  def self.failure_reason(job)
    error_file = job[:out] + '.error.txt'
    return File.read(error_file, encoding: 'UTF-8').strip if File.exist?(error_file)
    return File.readlines(job[:log], encoding: 'UTF-8').last(5).join.strip if File.exist?(job[:log])

    'AI 程式停咗，但冇講原因。'
  end

  # Adds the model as a component at the origin and returns its face count.
  def self.build(data, name, height)
    model = Sketchup.active_model
    build_height = [height, MIN_BUILD_HEIGHT].max
    points = data['vertices'].map { |x, y, z| Geom::Point3d.new(x * build_height, y * build_height, z * build_height) }

    model.start_operation('Photo to 3D', true)
    definition = model.definitions.add("相片變3D - #{name}")
    faces = if data['texture']
              build_textured(model, definition.entities, data, name, points)
            else
              build_colored(model, definition.entities, data, name, points)
            end

    scale = Geom::Transformation.scaling(height.to_f / build_height.to_f)
    instance = model.active_entities.add_instance(definition, scale)
    model.commit_operation

    model.selection.clear
    model.selection.add(instance)
    model.active_view.zoom(instance)
    faces
  rescue StandardError
    model.abort_operation
    raise
  end

  # Local engines: one plain-color material per palette color.
  def self.build_colored(model, entities, data, name, points)
    faces = data['faces']
    materials = data['palette'].each_with_index.map do |rgb, i|
      material = model.materials.add("相片變3D - #{name} #{i + 1}")
      material.color = Sketchup::Color.new(*rgb)
      material
    end

    smooth = Geom::PolygonMesh::AUTO_SOFTEN | Geom::PolygonMesh::SMOOTH_SOFT_EDGES
    faces.each_index.group_by { |i| data['face_colors'][i] }.each do |color, face_ids|
      mesh = Geom::PolygonMesh.new(face_ids.size * 3, face_ids.size)
      index = {}
      face_ids.each do |f|
        a, b, c = faces[f].map { |v| index[v] ||= mesh.add_point(points[v]) }
        mesh.add_polygon(a, b, c)
      end
      material = materials[color]
      entities.add_faces_from_mesh(mesh, smooth, material, material)
    end
    faces.size
  end

  # Meshy: one material with the real texture, mapped onto every triangle by its UVs.
  def self.build_textured(model, entities, data, name, points)
    material = model.materials.add("相片變3D - #{name}")
    material.texture = data['texture']
    uvs = data['uvs'].map { |u, v| Geom::Point3d.new(u, v, 1) }

    built = []
    add_all = lambda do |target|
      data['faces'].each do |triangle|
        face = target.add_face(*triangle.map { |i| points[i] })
        built << [face, triangle] if face
      rescue StandardError
        next # too small or too thin for SketchUp
      end
    end
    # Entities#build (SketchUp 2020.1+) adds thousands of faces much faster.
    entities.respond_to?(:build) ? entities.build { |builder| add_all.call(builder) } : add_all.call(entities)

    built.each do |face, triangle|
      mapping = triangle.flat_map { |i| [points[i], uvs[i]] }
      face.position_material(material, mapping, true)
      face.position_material(material, mapping, false)
    end

    entities.grep(Sketchup::Edge).each do |edge|
      sides = edge.faces
      next if sides.size == 2 && sides[0].normal.angle_between(sides[1].normal) > 40.degrees

      edge.soft = true
      edge.smooth = true
    end
    built.size
  end

  def self.open_work_folder
    FileUtils.mkdir_p(JOBS)
    UI.openURL("file:///#{JOBS}")
  end

  unless file_loaded?(__FILE__)
    Sketchup.require(File.join(PLUGIN_DIR, 'window'))

    menu = UI.menu('Extensions').add_submenu('相片變3D')
    menu.add_item('由相片整模型...') { Window.show }
    menu.add_item('開工作資料夾') { open_work_folder }

    command = UI::Command.new('相片變3D') { Window.show }
    command.small_icon = command.large_icon = File.join(PLUGIN_DIR, 'icon.svg')
    command.tooltip = '相片變3D'
    command.status_bar_text = '影一張物件相，AI 幫你變成 3D 模型。'
    toolbar = UI::Toolbar.new('Photo to 3D')
    toolbar.add_item(command)
    toolbar.get_last_state == TB_NEVER_SHOWN ? toolbar.show : toolbar.restore

    file_loaded(__FILE__)
  end
end
