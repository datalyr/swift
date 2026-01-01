Pod::Spec.new do |s|
  s.name             = 'DatalyrSDK'
  s.version          = '1.2.0'
  s.summary          = 'Server-side attribution tracking SDK for iOS'
  s.description      = <<-DESC
    Datalyr SDK for iOS with server-side tracking API support.
    Features include attribution tracking, SKAdNetwork integration,
    Apple Search Ads attribution, Meta and TikTok SDK integrations,
    offline event queuing, and automatic session management.
  DESC

  s.homepage         = 'https://datalyr.com'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Datalyr' => 'sdk@datalyr.com' }
  s.source           = {
    :git => 'https://github.com/datalyr/swift.git',
    :tag => s.version.to_s
  }

  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.0'

  s.source_files     = 'Sources/DatalyrSDK/**/*.swift'
  s.frameworks       = 'Foundation', 'UIKit', 'StoreKit', 'AdServices'
  s.weak_frameworks  = 'AdServices'

  s.requires_arc     = true
end