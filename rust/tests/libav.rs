//! **libavformat from a libmpv, read through `xtremio_core::libav`**: a
//! film made by `ffmpeg`, demuxed from bytes in memory through the custom
//! I/O context the app reads a media id through. It needs a libmpv whose
//! FFmpeg is the 6.x this build is bound to (`libmpv.so.2`, or
//! `XTREMIO_LIBMPV`) and an `ffmpeg` with libx264, and says so and passes
//! without them (CI's runners have neither).

#[path = "support/film.rs"]
mod film;
use film::{libmpv_name, make_film};

/// A film's bytes that fail -- as a cancelled or refused reader fails --
/// once `limit` of them have been read (short of the whole: a source read
/// to its end ends).
struct FailingAfter {
    bytes: std::io::Cursor<bytes::Bytes>,
    limit: u64,
}

impl xtremio_core::libav::Source for FailingAfter {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let len = self.bytes.get_ref().len() as u64;
        if self.bytes.position() >= self.limit && self.limit < len {
            return Err(std::io::Error::from(std::io::ErrorKind::Interrupted));
        }
        let room = (self.limit - self.bytes.position()) as usize;
        let take = buf.len().min(room);
        xtremio_core::libav::Source::read(&mut self.bytes, &mut buf[..take])
    }

    fn seek(&mut self, offset: u64) -> std::io::Result<u64> {
        xtremio_core::libav::Source::seek(&mut self.bytes, offset)
    }

    fn length(&self) -> u64 {
        xtremio_core::libav::Source::length(&self.bytes)
    }
}

/// **A source that breaks is not the end of the film.** The I/O callback
/// answers a failed read `AVERROR(EIO)`, never the end of file, and
/// libavformat hands that back out of `av_read_frame` wherever the read
/// broke -- so a run whose reader broke halfway fails rather than telling
/// the server the film ends there. The same film read whole ends.
#[test]
fn a_source_that_breaks_partway_is_a_failure_and_a_whole_one_an_end() -> anyhow::Result<()> {
    use xtremio_core::libav::{Demuxer, Libav, Next};
    let name = libmpv_name();
    let libav = match Libav::load(&name) {
        Ok(libav) => &*Box::leak(Box::new(libav)),
        Err(error) => {
            eprintln!("SKIPPED: no FFmpeg this build reads through {name}: {error}");
            return Ok(());
        }
    };
    let tmp = tempfile::tempdir()?;
    let film = tmp.path().join("film.mkv");
    if make_film(&film).is_none() {
        eprintln!("SKIPPED: no ffmpeg with libx264");
        return Ok(());
    }
    let bytes = bytes::Bytes::from(std::fs::read(&film)?);
    let read_to_the_end = |limit: u64| -> (usize, Next) {
        let source = FailingAfter {
            bytes: std::io::Cursor::new(bytes.clone()),
            limit,
        };
        let mut demuxer = Demuxer::open(libav, source).expect("the header reads");
        let mut packets = 0;
        loop {
            match demuxer.read_packet() {
                Next::Packet(_) => packets += 1,
                last => return (packets, last),
            }
        }
    };
    let (whole, end) = read_to_the_end(bytes.len() as u64);
    assert!(matches!(end, Next::End), "{end:?}");
    // Broken at many points, since where the read breaks decides which of
    // libavformat's paths reports it: inside a block, between clusters.
    let len = bytes.len() as u64;
    for limit in (1..64).map(|step| len * step / 64) {
        let (some, broken) = read_to_the_end(limit);
        assert!(
            matches!(broken, Next::Failed(_)),
            "broken at {limit} of {len}, after {some} packets: {broken:?}"
        );
        assert!(some < whole, "{some} of {whole}");
    }
    Ok(())
}

/// The sound of `file` (its one audio stream) decoded by
/// `xtremio_core::libav::SoundDecoder`: 48 kHz stereo, interleaved.
fn decoded_sound(libav: &'static xtremio_core::libav::Libav, file: &std::path::Path) -> Vec<f32> {
    use xtremio_core::libav::{Demuxer, Kind, Next, SoundDecoder};
    let bytes = bytes::Bytes::from(std::fs::read(file).unwrap());
    let mut demuxer = Demuxer::open(libav, std::io::Cursor::new(bytes)).expect("the header reads");
    let audio = demuxer
        .streams()
        .iter()
        .find(|stream| stream.kind == Kind::Audio)
        .expect("a sound track")
        .index;
    let par = demuxer.codec_parameters(audio).expect("its parameters");
    let mut packets = Vec::new();
    while let Next::Packet(packet) = demuxer.read_packet() {
        if packet.stream == audio {
            packets.push(packet);
        }
    }
    let mut decoder = SoundDecoder::new(par).unwrap().expect("a decoder");
    let pcm = decoder.decode(&packets).expect("it decodes");
    // The same packets decoded again: a fresh decoder, the same sound.
    assert_eq!(decoder.decode(&packets).unwrap(), pcm, "decoded twice");
    pcm.into_iter().flat_map(|block| block.samples).collect()
}

/// **Surround is mixed down to stereo at 48 kHz, LFE left out, and
/// normalised so nothing clips**: 5.1 and 7.1 FLAC with a level on each
/// channel (DC, so the mix is arithmetic), and mono at 44.1 kHz resampled.
/// The matrix is libswresample's default: centre and surrounds at -3 dB into
/// their side, divided by the largest row's sum (1 + 2 x 0.7071).
#[test]
fn surround_is_mixed_down_to_stereo_at_48_khz() -> anyhow::Result<()> {
    use xtremio_core::libav::Libav;
    let name = libmpv_name();
    let libav = match Libav::load(&name) {
        Ok(libav) => &*Box::leak(Box::new(libav)),
        Err(error) => {
            eprintln!("SKIPPED: no FFmpeg this build reads through {name}: {error}");
            return Ok(());
        }
    };
    let tmp = tempfile::tempdir()?;
    let make = |file: &str, source: &str, extra: &[&str]| -> Option<std::path::PathBuf> {
        let path = tmp.path().join(file);
        let mut args = vec![
            "-v", "error", "-y", "-f", "lavfi", "-i", source, "-c:a", "flac",
        ];
        args.extend_from_slice(extra);
        args.push(path.to_str()?);
        film::run("ffmpeg", &args)?.status.success().then_some(path)
    };
    // FL FR FC LFE BL BR.
    let Some(surround) = make(
        "51.mkv",
        "aevalsrc=exprs=0.4|0|0.2|0.9|0|0.1:s=48000:c=5.1:d=1",
        &[],
    ) else {
        eprintln!("SKIPPED: no ffmpeg");
        return Ok(());
    };
    let pcm = decoded_sound(libav, &surround);
    assert!(
        (pcm.len() / 2).abs_diff(48_000) < 64,
        "{} samples",
        pcm.len() / 2
    );
    let norm = 1.0 + 2.0 * std::f32::consts::FRAC_1_SQRT_2;
    let (left, right) = (pcm[2000], pcm[2001]);
    let expect_left = (0.4 + 0.2 * std::f32::consts::FRAC_1_SQRT_2) / norm;
    let expect_right =
        (0.2 * std::f32::consts::FRAC_1_SQRT_2 + 0.1 * std::f32::consts::FRAC_1_SQRT_2) / norm;
    assert!(
        (left - expect_left).abs() < 2e-3,
        "left {left}, {expect_left}"
    );
    assert!(
        (right - expect_right).abs() < 2e-3,
        "right {right}, {expect_right}"
    );

    // Six channels that say nothing of their speakers (PCM with an unknown
    // layout): taken as the usual six, 5.1, and mixed the same.
    let unknown = make(
        "6c.mkv",
        "aevalsrc=exprs=0.4|0|0.2|0.9|0|0.1:s=48000:c=5.1:d=1",
        &["-af", "aformat=channel_layouts=6c", "-c:a", "pcm_s16le"],
    )
    .expect("ffmpeg made unlabelled PCM");
    let pcm = decoded_sound(libav, &unknown);
    assert!((pcm[2000] - expect_left).abs() < 2e-3, "left {}", pcm[2000]);
    assert!(
        (pcm[2001] - expect_right).abs() < 2e-3,
        "right {}",
        pcm[2001]
    );

    // 7.1 (FL FR FC LFE BL BR SL SR): a side surround reaches its own side
    // only, the centre both alike, the LFE neither.
    for (exprs, check) in [
        (
            "0|0|0|0|0|0|0.5|0",
            Box::new(|l: f32, r: f32| l > 0.1 && r.abs() < 1e-3) as Box<dyn Fn(f32, f32) -> bool>,
        ),
        (
            "0|0|0.5|0|0|0|0|0",
            Box::new(|l: f32, r: f32| l > 0.1 && (l - r).abs() < 1e-3),
        ),
        (
            "0|0|0|0.9|0|0|0|0",
            Box::new(|l: f32, r: f32| l.abs() < 1e-3 && r.abs() < 1e-3),
        ),
    ] {
        let source = format!("aevalsrc=exprs={exprs}:s=48000:c=7.1:d=1");
        let file = make("71.mkv", &source, &[]).expect("ffmpeg made 7.1");
        let pcm = decoded_sound(libav, &file);
        assert!(
            check(pcm[2000], pcm[2001]),
            "{exprs}: {} {}",
            pcm[2000],
            pcm[2001]
        );
    }

    // Mono at 44.1 kHz: a second of it is a second at 48 kHz, on both sides.
    let mono = make(
        "mono.mkv",
        "sine=frequency=440:sample_rate=44100:duration=1",
        &["-ac", "1"],
    )
    .expect("ffmpeg made mono");
    let pcm = decoded_sound(libav, &mono);
    assert!(
        (pcm.len() / 2).abs_diff(48_000) < 64,
        "{} samples",
        pcm.len() / 2
    );
    assert!(pcm.as_chunks::<2>().0.iter().all(|[l, r]| l == r));
    assert!(
        pcm.iter().any(|sample| sample.abs() > 0.05),
        "the tone is there"
    );
    Ok(())
}
