# Audio fixture

`tone.mp3` is a one-second, 440 Hz stereo tone generated for decoder regression tests.
It contains no speech or third-party recording. Reproduce it with FFmpeg:

```sh
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100:duration=1 -ac 2 \
  -c:a libmp3lame -b:a 64k -write_xing 0 -map_metadata -1 tone.mp3
```

This resource is bundled only in SwiftPM tests, not in the iOS app.
