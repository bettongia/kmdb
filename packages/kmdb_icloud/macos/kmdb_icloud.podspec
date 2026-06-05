#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint kmdb_icloud.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'kmdb_icloud'
  s.version          = '0.1.0'
  s.summary          = 'Apple iCloud (CloudKit) sync adapter plugin for KMDB.'
  s.description      = <<-DESC
Provides the ICloudSyncPlugin that bridges the Dart ICloudSyncChannel
interface to the native CloudKit framework. Used by kmdb_icloud to implement
SyncStorageAdapter over CloudKit custom zones.
  DESC
  s.homepage         = 'https://github.com/bettongia/kmdb'
  s.license          = { :type => 'Apache 2.0', :file => '../LICENSE' }
  s.author           = { 'Bettongia' => 'dev@bettongia.au' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
