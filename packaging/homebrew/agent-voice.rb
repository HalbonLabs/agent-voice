# Homebrew formula template for HalbonLabs/homebrew-tap. Update the url and
# sha256 per release (sha256 from: shasum -a 256 <tarball>).
class AgentVoice < Formula
  desc "Grounded, fact-checked spoken summaries for AI coding agents"
  homepage "https://github.com/HalbonLabs/agent-voice"
  url "https://github.com/HalbonLabs/agent-voice/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  license "MIT"

  depends_on "node"

  def install
    libexec.install Dir["*"]
    (bin/"agent-voice").write <<~SH
      #!/bin/bash
      exec node "#{libexec}/bin/agent-voice.mjs" "$@"
    SH
  end

  def caveats
    <<~EOS
      Run `agent-voice install` to wire the hooks into your agents.
      Python 3.10-3.12 is needed only for the Kokoro engine.
    EOS
  end

  test do
    assert_match "usage", shell_output("#{bin}/agent-voice help 2>&1", 2)
  end
end
