use std::{thread, time::Duration};
#[cfg(not(target_os = "android"))]
use std::sync::{Arc, atomic::{AtomicUsize, Ordering}, mpsc};

#[derive(Debug, PartialEq, Eq)]
pub enum Playback { Complete, Skipped }

#[cfg(not(target_os = "android"))]
#[derive(Debug, PartialEq, Eq)]
enum Attempt { Complete, NeverStarted, Stalled }

#[cfg(not(target_os = "android"))]
fn with_fresh_device(mut attempt: impl FnMut() -> Result<Attempt, String>) -> Result<Playback, String> {
    let mut result = attempt()?;
    if result == Attempt::NeverStarted {
        result = attempt()?;
    }
    Ok(if result == Attempt::Complete { Playback::Complete } else { Playback::Skipped })
}

#[cfg(not(target_os = "android"))]
pub fn play(pcm: Vec<[f32; 2]>, rate: u32) -> Result<Playback, String> {
    let pcm: Arc<[[f32; 2]]> = pcm.into();
    with_fresh_device(|| play_once(Arc::clone(&pcm), rate))
}

#[cfg(not(target_os = "android"))]
fn play_once(pcm: Arc<[[f32; 2]]>, rate: u32) -> Result<Attempt, String> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let device = cpal::default_host().default_output_device().ok_or("No audio output device")?;
    // A device that cannot be opened is no output at all: ALSA without a
    // reachable sound server reports snd_pcm_open failing with EHOSTDOWN.
    let supported = device.default_output_config().map_err(|e| format!("No audio output device: {e}"))?;
    let config = supported.config();
    match supported.sample_format() {
        cpal::SampleFormat::F32 => desktop::<f32>(&device, &config, pcm, rate),
        cpal::SampleFormat::I16 => desktop::<i16>(&device, &config, pcm, rate),
        cpal::SampleFormat::U16 => desktop::<u16>(&device, &config, pcm, rate),
        format => Err(format!("Unsupported audio output format: {format}")),
    }
}

#[cfg(not(target_os = "android"))]
fn desktop<T: cpal::SizedSample + cpal::FromSample<f32>>(
    device: &cpal::Device, config: &cpal::StreamConfig, pcm: Arc<[[f32; 2]]>, rate: u32,
) -> Result<Attempt, String> {
    use cpal::traits::{DeviceTrait, StreamTrait};
    let progress = Arc::new(AtomicUsize::new(0));
    let rendered = Arc::clone(&progress);
    let channels = config.channels as usize;
    let step = rate as f64 / config.sample_rate as f64;
    let (tx, rx) = mpsc::channel();
    let errors = tx.clone();
    let mut cursor: f64 = 0.0;
    let mut finished = false;
    let stream = device.build_output_stream(*config, move |out: &mut [T], _| {
        for frame in out.chunks_mut(channels) {
            let index = cursor as usize;
            let a = pcm.get(index).copied().unwrap_or([0.0; 2]);
            let b = pcm.get(index + 1).copied().unwrap_or(a);
            let fraction = cursor.fract() as f32;
            let pair = [a[0] + (b[0] - a[0]) * fraction, a[1] + (b[1] - a[1]) * fraction];
            for (channel, sample) in frame.iter_mut().enumerate() {
                *sample = T::from_sample(if channels == 1 { (pair[0] + pair[1]) * 0.5 }
                    else { pair.get(channel).copied().unwrap_or(0.0) });
            }
            cursor += step;
        }
        rendered.store((cursor as usize).min(pcm.len()), Ordering::Relaxed);
        if cursor >= pcm.len() as f64 && !finished {
            finished = true;
            let _ = tx.send(Ok(()));
        }
    }, move |e| { let _ = errors.send(Err(e.to_string())); }, None)
        .map_err(|e| format!("No audio output device: {e}"))?;
    stream.play().map_err(|e| format!("No audio output device: {e}"))?;
    if !wait_for_output(rx, &progress, Duration::from_secs(3))? {
        // Close before deciding to retry: the callback may have run during teardown.
        drop(stream);
        return Ok(if progress.load(Ordering::Relaxed) == 0 { Attempt::NeverStarted } else { Attempt::Stalled });
    }
    // Drain the last output buffer before dropping the device.
    thread::sleep(Duration::from_millis(250));
    drop(stream);
    Ok(Attempt::Complete)
}

#[cfg(not(target_os = "android"))]
fn wait_for_output(
    completion: mpsc::Receiver<Result<(), String>>, progress: &AtomicUsize, timeout: Duration,
) -> Result<bool, String> {
    let mut previous = 0;
    loop {
        match completion.recv_timeout(timeout) {
            Ok(result) => return result.map(|()| true),
            Err(mpsc::RecvTimeoutError::Disconnected) => return Err("Audio output disconnected".into()),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let current = progress.load(Ordering::Relaxed);
                if current == previous { return Ok(false); }
                previous = current;
            }
        }
    }
}

#[cfg(target_os = "android")]
#[allow(non_snake_case)]
pub fn play(pcm: Vec<[f32; 2]>, rate: u32) -> Result<Playback, String> {
    use std::{ffi::c_void, ptr};
    // AAudio is available on every supported Android version. No Activity or
    // microphone permission is needed; opening happens only on this worker.
    unsafe {
        let lib = libloading::Library::new("libaaudio.so").map_err(|e| e.to_string())?;
        macro_rules! sym {
            ($name:ident, $ty:ty) => {
                let $name = *lib.get::<$ty>(concat!(stringify!($name), "\0").as_bytes()).map_err(|e| e.to_string())?;
            };
        }
        sym!(AAudio_createStreamBuilder, unsafe extern "C" fn(*mut *mut c_void) -> i32);
        sym!(AAudioStreamBuilder_delete, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStreamBuilder_setFormat, unsafe extern "C" fn(*mut c_void, i32));
        sym!(AAudioStreamBuilder_setChannelCount, unsafe extern "C" fn(*mut c_void, i32));
        sym!(AAudioStreamBuilder_setSampleRate, unsafe extern "C" fn(*mut c_void, i32));
        sym!(AAudioStreamBuilder_openStream, unsafe extern "C" fn(*mut c_void, *mut *mut c_void) -> i32);
        sym!(AAudioStream_requestStart, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_requestStop, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_close, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_write, unsafe extern "C" fn(*mut c_void, *const c_void, i32, i64) -> i32);
        sym!(AAudioStream_getBufferSizeInFrames, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_getSampleRate, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_getChannelCount, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_getFormat, unsafe extern "C" fn(*mut c_void) -> i32);
        let mut builder = ptr::null_mut();
        if AAudio_createStreamBuilder(&mut builder) != 0 { return Err("Cannot create audio output".into()); }
        // Defaults: output, shared mode, media usage. Match decoded stereo PCM.
        AAudioStreamBuilder_setFormat(builder, 2); // PCM_FLOAT
        AAudioStreamBuilder_setChannelCount(builder, 2);
        AAudioStreamBuilder_setSampleRate(builder, rate as i32);
        let mut stream = ptr::null_mut();
        let opened = AAudioStreamBuilder_openStream(builder, &mut stream);
        AAudioStreamBuilder_delete(builder);
        if opened != 0 || stream.is_null() { return Err(format!("Cannot open audio output: {opened}")); }
        let result = (|| {
            if AAudioStream_getSampleRate(stream) != rate as i32
                || AAudioStream_getChannelCount(stream) != 2 || AAudioStream_getFormat(stream) != 2 {
                return Err("Audio output did not provide the requested stereo PCM format".into());
            }
            let started = AAudioStream_requestStart(stream);
            if started != 0 { return Err(format!("Cannot start audio output: {started}")); }
            let mut position = 0;
            while position < pcm.len() {
                let count = AAudioStream_write(stream, pcm[position..].as_ptr().cast(),
                    (pcm.len() - position).min(4096) as i32, 1_000_000_000);
                if count <= 0 { return Err(format!("Audio output write failed: {count}")); }
                position += count as usize;
            }
            let drain = AAudioStream_getBufferSizeInFrames(stream).max(0) as f64 / rate as f64;
            thread::sleep(Duration::from_secs_f64(drain + 0.05));
            Ok(())
        })();
        AAudioStream_requestStop(stream);
        AAudioStream_close(stream);
        result.map(|()| Playback::Complete)
    }
}

#[cfg(all(test, not(target_os = "android")))]
mod tests {
    use super::*;

    #[test]
    fn stalled_output_expires_and_device_failures_remain_errors() {
        let progress = AtomicUsize::new(0);
        let (tx, rx) = mpsc::channel();
        assert!(!wait_for_output(rx, &progress, Duration::from_millis(1)).unwrap());
        drop(tx);
        let (tx, rx) = mpsc::channel();
        tx.send(Err("device lost".into())).unwrap();
        assert_eq!(wait_for_output(rx, &progress, Duration::ZERO), Err("device lost".into()));
    }

    #[test]
    fn retry_only_when_no_frames_rendered() {
        for (attempts, expected) in [
            (vec![Attempt::NeverStarted, Attempt::Complete], Playback::Complete),
            (vec![Attempt::NeverStarted, Attempt::NeverStarted], Playback::Skipped),
            (vec![Attempt::Stalled], Playback::Skipped),
            (vec![Attempt::Complete], Playback::Complete),
        ] {
            let mut results = attempts.into_iter();
            assert_eq!(with_fresh_device(|| Ok(results.next().unwrap())).unwrap(), expected);
            assert!(results.next().is_none());
        }
    }
}
