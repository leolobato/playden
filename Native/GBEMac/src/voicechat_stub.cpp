// Playden macOS port of gbe_fork: voice chat stub.
//
// Replaces gbe_fork's dll/voicechat.cpp, which needs opus + portaudio. Voice
// chat is compiled out on macOS because:
//   - opening the microphone from a game that has no NSMicrophoneUsageDescription
//     in its Info.plist makes TCC terminate the process, and
//   - voice chat is off by default in gbe_fork (enable_voice_chat=0) anyway.
// The behaviour matches upstream when PortAudio fails to initialize: every
// call reports "not initialized" / "no data" and nothing is recorded or played.
// Built with EMU_NO_VOICECHAT (see patches/0005-voicechat-optional.patch).

#include "dll/voicechat.h"

void VoiceChat::cleanupVoiceRecordingInternal() {}
void VoiceChat::cleanupPlaybackInternal() {}

int VoiceChat::inputCallback(const void *, void *, unsigned long,
    const PaStreamCallbackTimeInfo *, PaStreamCallbackFlags, void *) { return 0; }

int VoiceChat::outputCallback(const void *, void *, unsigned long,
    const PaStreamCallbackTimeInfo *, PaStreamCallbackFlags, void *) { return 0; }

VoiceChat::~VoiceChat() {}

bool VoiceChat::InitVoiceSystem() { return false; }
void VoiceChat::ShutdownVoiceSystem() {}
bool VoiceChat::StartVoiceRecording() { return false; }
void VoiceChat::StopVoiceRecording() {}
bool VoiceChat::StartVoicePlayback() { return false; }
void VoiceChat::StopVoicePlayback() {}

EVoiceResult VoiceChat::GetAvailableVoice(uint32_t *pcbCompressed)
{
    if (pcbCompressed) *pcbCompressed = 0;
    return k_EVoiceResultNotInitialized;
}

EVoiceResult VoiceChat::GetVoice(bool, void *, uint32_t, uint32_t *nBytesWritten)
{
    if (nBytesWritten) *nBytesWritten = 0;
    return k_EVoiceResultNotInitialized;
}

EVoiceResult VoiceChat::DecompressVoice(const void *, uint32_t, void *, uint32_t,
    uint32_t *nBytesWritten, uint32_t)
{
    if (nBytesWritten) *nBytesWritten = 0;
    return k_EVoiceResultNotInitialized;
}

void VoiceChat::QueueAudioPlayback(uint64_t, const uint8_t *, size_t) {}

bool VoiceChat::IsVoiceSystemInitialized() const { return false; }
bool VoiceChat::IsRecordingActive() const { return false; }
bool VoiceChat::IsPlaybackActive() const { return false; }
