#
# Podspec for the Hopcast Flutter plugin (iOS).
# The proprietary core is consumed ONLY as a hardened binary XCFramework
# (Frameworks/HopcastSDKKit.xcframework). No SDK .swift source is bundled here —
# only the binary, exactly like the Android .aar.
#
Pod::Spec.new do |s|
  s.name             = 'hopcast_flutter'
  s.version          = '0.4.0'
  s.summary          = 'Hopcast device-to-device (D2D) file sharing for Flutter (iOS).'
  s.description      = <<-DESC
Flutter/iOS bridge to the Hopcast SDK (device-to-device file sharing: offline, online and hybrid modes).
The SDK is vendored as a hardened binary XCFramework; only the Swift glue (channels) is visible.
                       DESC
  s.homepage         = 'https://github.com/Hopcast/hopcast-sdk-flutter'
  s.license          = { :type => 'Proprietary', :text => 'Proprietary — Hopcast' }
  s.author           = { 'Hopcast' => 'contact@hopcast.io' }
  s.source           = { :path => '.' }

  # Swift glue (plugin + bridge). No SDK source here.
  s.source_files     = 'Classes/**/*'

  # The hardened SDK, as a binary (device + simulator). Module "HopcastSDKKit" (≠ the public
  # type `HopcastSDK`) to avoid the module/type collision in the distribution .swiftinterface.
  s.vendored_frameworks = 'Frameworks/HopcastSDKKit.xcframework'

  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.swift_version = '5.0'

  # Required for a Swift module + embedded dynamic framework.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
