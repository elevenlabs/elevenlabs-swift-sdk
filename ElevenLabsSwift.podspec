Pod::Spec.new do |spec|

  spec.name         = "ElevenLabsSwift"
  spec.version      = "1.0.1"
  spec.summary      = "ElevenLabs Conversational AI Swift SDK (experimental)"

  spec.description  = <<-DESC
    ElevenLabs Conversational AI Swift SDK is a framework designed to integrate ElevenLabs' powerful conversational AI capabilities into your Swift applications. It enables advanced audio processing and WebSocket communication for building intelligent conversational voice experiences. Currently, the focus is on conversational AI, with plans to support additional features like speech synthesis in future releases.
  DESC

  spec.homepage     = "https://github.com/elevenlabs/ElevenLabsSwift"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "elevenlabs" => "support@elevenlabs.io" }
  spec.social_media_url = "https://twitter.com/elevenlabs"

  spec.platform     = :ios, "15.0"
  spec.source = { :git => "https://github.com/elevenlabs/ElevenLabsSwift.git", :tag => "v#{spec.version}" }

  spec.source_files  = "Sources/ElevenLabsSwift/**/*.{swift}"
  
  spec.requires_arc = true

end
