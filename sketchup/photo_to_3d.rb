# encoding: utf-8
require 'sketchup.rb'
require 'extensions.rb'

module PhotoTo3D
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new('相片變3D (Photo to 3D)', 'photo_to_3d/main')
    extension.description = '用免費 AI（Hunyuan3D-2 mini 或 TripoSR）將物件相片變成 3D 模型。'
    extension.version = '1.1.0'
    extension.creator = 'yiukwanwa'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
