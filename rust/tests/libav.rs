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
