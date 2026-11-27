extends "res://tests/unit/test_case.gd"

const Agents := preload("res://scenes/Agents.gd")


## A machine with no usable audio output only misses the sound; that is logged
## quietly. Any other failure is still an error.
func test_missing_audio_output_is_not_an_error() -> void:
	for failure in [
		"No audio output device",
		"No audio output device: snd_pcm_open failed (EHOSTDOWN)",
		"Unsupported audio output format: I24",
	]:
		expect(Agents.audio_unavailable(failure), "Quiet: " + failure)
	for failure in ["Audio stream failed", "Unsupported audio output format", "no audio output device"]:
		expect(not Agents.audio_unavailable(failure), "Still an error: " + failure)
