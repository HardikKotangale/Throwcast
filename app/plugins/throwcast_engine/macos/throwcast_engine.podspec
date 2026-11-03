Pod::Spec.new do |s|
  s.name = 'throwcast_engine'
  s.version = '1.0.0'
  s.summary = 'Screen capture, encoding and streaming for Throwcast.'
  s.homepage = 'https://localhost'
  s.license = { :type => 'MIT' }
  s.author = 'Throwcast'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/Bridge/CVirtualDisplay.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '15.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
