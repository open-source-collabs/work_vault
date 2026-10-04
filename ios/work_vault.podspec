Pod::Spec.new do |s|
  s.name             = 'work_vault'
  s.version          = '0.1.0'
  s.summary          = 'Resumable HTTPS GET downloads for Flutter that continue after the UI is gone.'
  s.description      = <<-DESC
Resumable HTTPS GET downloads for Flutter. Work continues in WorkManager on Android and a background URLSession on iOS.
                       DESC
  s.homepage         = 'https://pub.dev/packages/work_vault'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = 'Abdulrahman'
  s.source           = { :path => '.' }
  s.source_files     = 'work_vault/Sources/work_vault/**/*'
  s.resource_bundles = { 'work_vault_privacy' => ['work_vault/Sources/work_vault/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
