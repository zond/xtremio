//! **Where in its cluster each Matroska cue's block is**: the one thing
//! libavformat's index of a Matroska file drops.
//!
//! A rendition's byte layout mirrors its source (stream-server
//! `docs/design/renditions.md` §2.8): each segment's slot is as long as
//! the source's bytes from one sync sample to the next. libavformat's index
//! of a Matroska file puts every cue at its **cluster's** position
//! (`matroska_add_index_entries` reads `CueClusterPosition` and leaves
//! `CueRelativePosition` unread, n6.0), and a cluster is not cut at every
//! sync sample: mkvmerge cuts them every few seconds wherever the blocks
//! fall, so a sync sample can sit seconds of data into its cluster. A
//! slot mirrored from the cluster would be wrong by that much. The cue's
//! `CueRelativePosition` -- the block's offset from the start of the
//! cluster's data -- says where the block is, and this reads it: the
//! Segment's `SeekHead` for where the `Cues` are, then the `Cues`.
//!
//! The cluster's own header (its ID and its size, four bytes and one to
//! eight) is not read -- that would be a read per cue, all over the file --
//! so a block's position is put [`CLUSTER_HEADER`] past the cluster: up to
//! seven bytes late, which the slot's headroom absorbs.

use std::collections::HashMap;
use std::io;

/// The most a cluster's header can be: its four-byte ID and an eight-byte
/// size.
pub const CLUSTER_HEADER: u64 = 12;

const EBML: u32 = 0x1A45_DFA3;
const SEGMENT: u32 = 0x1853_8067;
const SEEK_HEAD: u32 = 0x114D_9B74;
const SEEK: u32 = 0x4DBB;
const SEEK_ID: u32 = 0x53AB;
const SEEK_POSITION: u32 = 0x53AC;
const CUES: u32 = 0x1C53_BB6B;
const CLUSTER: u32 = 0x1F43_B675;
const CUE_POINT: u32 = 0xBB;
const CUE_TIME: u32 = 0xB3;
const CUE_TRACK_POSITIONS: u32 = 0xB7;
const CUE_TRACK: u32 = 0xF7;
const CUE_CLUSTER_POSITION: u32 = 0xF1;
const CUE_RELATIVE_POSITION: u32 = 0xF0;

/// How much of the file's start is read for the header and the `SeekHead`.
const HEAD: usize = 64 * 1024;
/// The largest `Cues` element read: a cue per sync sample of a long film is
/// well under this.
const MAX_CUES: u64 = 32 * 1024 * 1024;

/// One cue's position for one track.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cue {
    pub track: u64,
    /// In the Segment's timestamp scale, as libavformat's index has it.
    pub time: u64,
    /// The cluster's position from the Segment's data.
    pub cluster: u64,
    /// The block's position from the cluster's data, when the cue says.
    pub relative: Option<u64>,
}

/// A file's cues, and where its Segment's data begins.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cues {
    pub segment_start: u64,
    pub cues: Vec<Cue>,
}

impl Cues {
    /// Where each cue puts its block, by (`time`, the cluster's absolute
    /// position) -- the key libavformat's index entries carry -- for the
    /// track whose cues are `keys` (the video's index entries): the track
    /// most of them are cues of. libavformat does not say which Matroska
    /// track a stream is (`AVStream.id` is 0), and a cue for the sound at
    /// the same time and cluster would put the block elsewhere.
    pub fn blocks(&self, keys: &[(u64, u64)]) -> HashMap<(u64, u64), u64> {
        let key = |cue: &Cue| (cue.time, self.segment_start + cue.cluster);
        let wanted: std::collections::HashSet<(u64, u64)> = keys.iter().copied().collect();
        let mut matches: HashMap<u64, usize> = HashMap::new();
        for cue in &self.cues {
            if wanted.contains(&key(cue)) {
                *matches.entry(cue.track).or_default() += 1;
            }
        }
        let Some(track) = matches
            .into_iter()
            .max_by_key(|(track, count)| (*count, std::cmp::Reverse(*track)))
            .map(|(track, _)| track)
        else {
            return HashMap::new();
        };
        self.cues
            .iter()
            .filter(|cue| cue.track == track)
            .filter_map(|cue| {
                let (time, cluster) = key(cue);
                cue.relative
                    .map(|relative| ((time, cluster), cluster + CLUSTER_HEADER + relative))
            })
            .collect()
    }
}

/// An element's ID, kept with its marker bits as the spec writes IDs, and
/// how many bytes it took.
fn element_id(data: &[u8]) -> Option<(u32, usize)> {
    let first = *data.first()?;
    let len = first.leading_zeros() as usize + 1;
    if len > 4 || data.len() < len {
        return None;
    }
    let id = data[..len]
        .iter()
        .fold(0u32, |id, byte| (id << 8) | u32::from(*byte));
    Some((id, len))
}

/// An element's size and how many bytes it took; `None` for the size an
/// unknown-size element (a live stream's Segment) writes.
fn element_size(data: &[u8]) -> Option<(Option<u64>, usize)> {
    let first = *data.first()?;
    let len = first.leading_zeros() as usize + 1;
    if len > 8 || data.len() < len {
        return None;
    }
    let mask = if len == 8 { 0 } else { 0xffu8 >> len };
    let mut value = u64::from(first & mask);
    let mut all_ones = first & mask == mask;
    for byte in &data[1..len] {
        value = (value << 8) | u64::from(*byte);
        all_ones &= *byte == 0xff;
    }
    Some(((!all_ones).then_some(value), len))
}

/// One element in `data` at `at`: its ID, where its body starts, and its
/// size (`None` when unknown).
fn element(data: &[u8], at: usize) -> Option<(u32, usize, Option<u64>)> {
    let (id, id_len) = element_id(data.get(at..)?)?;
    let (size, size_len) = element_size(data.get(at + id_len..)?)?;
    Some((id, at + id_len + size_len, size))
}

/// The children of a master element's body, as `(id, body)`.
fn children(body: &[u8]) -> Vec<(u32, &[u8])> {
    let mut out = Vec::new();
    let mut at = 0;
    while let Some((id, start, Some(size))) = element(body, at) {
        let Some(end) = start
            .checked_add(size as usize)
            .filter(|end| *end <= body.len())
        else {
            break;
        };
        out.push((id, &body[start..end]));
        at = end;
    }
    out
}

fn uint(body: &[u8]) -> u64 {
    body.iter()
        .take(8)
        .fold(0u64, |value, byte| (value << 8) | u64::from(*byte))
}

/// What a `SeekHead` says: where the `Cues` are, and where another
/// `SeekHead` is, from the Segment's data.
fn seek_head(body: &[u8]) -> (Option<u64>, Option<u64>) {
    let (mut cues, mut more) = (None, None);
    for (id, seek) in children(body) {
        if id != SEEK {
            continue;
        }
        let entries = children(seek);
        let target = entries
            .iter()
            .find(|(id, _)| *id == SEEK_ID)
            .and_then(|(_, body)| element_id(body).map(|(id, _)| id));
        let position = entries
            .iter()
            .find(|(id, _)| *id == SEEK_POSITION)
            .map(|(_, body)| uint(body));
        match (target, position) {
            (Some(CUES), Some(position)) => cues = Some(position),
            (Some(SEEK_HEAD), Some(position)) => more = Some(position),
            _ => {}
        }
    }
    (cues, more)
}

/// The cue points in a `Cues` element's body.
pub fn parse_cues(body: &[u8]) -> Vec<Cue> {
    let mut out = Vec::new();
    for (id, point) in children(body) {
        if id != CUE_POINT {
            continue;
        }
        let fields = children(point);
        let Some(time) = fields
            .iter()
            .find(|(id, _)| *id == CUE_TIME)
            .map(|(_, body)| uint(body))
        else {
            continue;
        };
        for (_, positions) in fields.iter().filter(|(id, _)| *id == CUE_TRACK_POSITIONS) {
            let fields = children(positions);
            let field = |want: u32| {
                fields
                    .iter()
                    .find(|(id, _)| *id == want)
                    .map(|(_, body)| uint(body))
            };
            if let (Some(track), Some(cluster)) = (field(CUE_TRACK), field(CUE_CLUSTER_POSITION)) {
                out.push(Cue {
                    track,
                    time,
                    cluster,
                    relative: field(CUE_RELATIVE_POSITION),
                });
            }
        }
    }
    out
}

/// **A Matroska file's cues**, read through `read_at(offset, len)` (up to
/// `len` bytes of the file at `offset`): the EBML header, the Segment, its
/// `SeekHead` (or one more it names) for the `Cues`' position, then the
/// `Cues`. `Ok(None)` for a file that has none, or none this can find.
pub fn read_cues(
    read_at: &mut dyn FnMut(u64, usize) -> io::Result<Vec<u8>>,
) -> io::Result<Option<Cues>> {
    let head = read_at(0, HEAD)?;
    let Some((EBML, ebml_body, Some(ebml_size))) = element(&head, 0) else {
        return Ok(None);
    };
    let segment_at = ebml_body + ebml_size as usize;
    let Some((SEGMENT, segment_start, _)) = element(&head, segment_at) else {
        return Ok(None);
    };
    // The Segment's first children, as far as the head reaches: a SeekHead
    // first, as every muxer writes one; Cues here too, when a muxer put them
    // up front.
    let (mut cues_at, mut more) = (None, None);
    let mut at = segment_start;
    while let Some((id, start, Some(size))) = element(&head, at) {
        match id {
            SEEK_HEAD => {
                if let Some(body) = head.get(start..start + size as usize) {
                    let (cues, other) = seek_head(body);
                    cues_at = cues_at.or(cues);
                    more = more.or(other);
                }
            }
            CUES => cues_at = cues_at.or(Some((at - segment_start) as u64)),
            CLUSTER => break,
            _ => {}
        }
        at = start + size as usize;
    }
    let segment_start = segment_start as u64;
    if let (None, Some(other)) = (cues_at, more) {
        let second = read_at(segment_start + other, HEAD)?;
        if let Some((SEEK_HEAD, start, Some(size))) = element(&second, 0) {
            if let Some(body) = second.get(start..start + size as usize) {
                cues_at = seek_head(body).0;
            }
        }
    }
    let Some(cues_at) = cues_at else {
        return Ok(None);
    };
    let at = segment_start + cues_at;
    let header = read_at(at, 12)?;
    let Some((CUES, body, Some(size))) = element(&header, 0) else {
        return Ok(None);
    };
    if size > MAX_CUES {
        return Ok(None);
    }
    let cues = read_at(at + body as u64, size as usize)?;
    Ok(Some(Cues {
        segment_start,
        cues: parse_cues(&cues),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An element: its ID's bytes, an eight-byte size, the body.
    fn el(id: u32, body: &[u8]) -> Vec<u8> {
        let id_bytes = id.to_be_bytes();
        let skip = id_bytes.iter().position(|byte| *byte != 0).unwrap_or(3);
        let mut out = id_bytes[skip..].to_vec();
        out.push(0x01);
        out.extend_from_slice(&(body.len() as u64).to_be_bytes()[1..]);
        out.extend_from_slice(body);
        out
    }

    fn num(value: u64) -> Vec<u8> {
        value.to_be_bytes().to_vec()
    }

    fn cue_point(time: u64, track: u64, cluster: u64, relative: Option<u64>) -> Vec<u8> {
        let mut positions = el(CUE_TRACK, &num(track));
        positions.extend(el(CUE_CLUSTER_POSITION, &num(cluster)));
        if let Some(relative) = relative {
            positions.extend(el(CUE_RELATIVE_POSITION, &num(relative)));
        }
        let mut point = el(CUE_TIME, &num(time));
        point.extend(el(CUE_TRACK_POSITIONS, &positions));
        el(CUE_POINT, &point)
    }

    /// A `Void` element padding `body` to `len` bytes.
    fn pad_to(body: &mut Vec<u8>, len: usize) {
        let filler = len - body.len() - 9;
        body.extend(el(0xEC, &vec![0; filler]));
    }

    /// A file: the EBML header, a Segment holding a SeekHead that names the
    /// Cues -- or a second SeekHead, past the first 64 KiB, that does --
    /// then the Cues. Everything after the first SeekHead is beyond what
    /// the head read reaches, as a film's Cues are.
    fn film(cues: &[u8], through_second: bool) -> (Vec<u8>, u64) {
        let ebml = el(EBML, &el(0x4282, b"matroska"));
        let seek = |target: u32, position: u64| {
            let mut entry = el(SEEK_ID, &target.to_be_bytes());
            entry.extend(el(SEEK_POSITION, &num(position)));
            el(SEEK, &entry)
        };
        let far = 70_000usize;
        let cues_at = if through_second { far + 200 } else { far };
        let mut segment_body = if through_second {
            el(SEEK_HEAD, &seek(SEEK_HEAD, far as u64))
        } else {
            el(SEEK_HEAD, &seek(CUES, cues_at as u64))
        };
        pad_to(&mut segment_body, far);
        if through_second {
            segment_body.extend(el(SEEK_HEAD, &seek(CUES, cues_at as u64)));
            pad_to(&mut segment_body, cues_at);
        }
        segment_body.extend(el(CUES, cues));
        let mut file = ebml.clone();
        let segment = el(SEGMENT, &segment_body);
        let segment_start = (ebml.len() + segment.len() - segment_body.len()) as u64;
        file.extend(segment);
        (file, segment_start)
    }

    fn reader(file: &[u8]) -> impl FnMut(u64, usize) -> io::Result<Vec<u8>> + '_ {
        |offset, len| {
            let start = (offset as usize).min(file.len());
            Ok(file[start..(start + len).min(file.len())].to_vec())
        }
    }

    /// **The cues' block positions, through the SeekHead**: each cue's
    /// track, time, cluster and position in it; a cue without
    /// `CueRelativePosition` keeps its cluster only.
    #[test]
    fn the_cues_are_found_through_the_seek_head() {
        let mut cues = cue_point(0, 1, 500, Some(30));
        cues.extend(cue_point(0, 2, 500, Some(10)));
        cues.extend(cue_point(2002, 1, 90_000, Some(4_000)));
        cues.extend(cue_point(4004, 1, 200_000, None));
        let (file, segment_start) = film(&cues, false);
        let found = read_cues(&mut reader(&file)).unwrap().expect("cues");
        assert_eq!(found.segment_start, segment_start);
        assert_eq!(
            found.cues,
            vec![
                Cue {
                    track: 1,
                    time: 0,
                    cluster: 500,
                    relative: Some(30)
                },
                Cue {
                    track: 2,
                    time: 0,
                    cluster: 500,
                    relative: Some(10)
                },
                Cue {
                    track: 1,
                    time: 2002,
                    cluster: 90_000,
                    relative: Some(4_000)
                },
                Cue {
                    track: 1,
                    time: 4004,
                    cluster: 200_000,
                    relative: None
                },
            ]
        );
        // The video's index: track 1's times and clusters, which track 2's
        // cue at 0 shares.
        let keys: Vec<(u64, u64)> = [(0, 500), (2002, 90_000), (4004, 200_000)]
            .iter()
            .map(|(time, cluster)| (*time, segment_start + cluster))
            .collect();
        let blocks = found.blocks(&keys);
        assert_eq!(
            blocks.len(),
            2,
            "track 1's, and not the cue that does not say"
        );
        assert_eq!(
            blocks[&(0, segment_start + 500)],
            segment_start + 500 + CLUSTER_HEADER + 30,
            "the video's block, not the sound's"
        );
        assert_eq!(
            blocks[&(2002, segment_start + 90_000)],
            segment_start + 90_000 + CLUSTER_HEADER + 4_000
        );
    }

    /// A SeekHead that names another, which names the Cues (mkvmerge puts
    /// one at the end), is followed once.
    #[test]
    fn a_second_seek_head_is_followed() {
        let cues = cue_point(0, 1, 500, Some(30));
        let (file, _) = film(&cues, true);
        let found = read_cues(&mut reader(&file)).unwrap().expect("cues");
        assert_eq!(found.cues.len(), 1);
    }

    /// Not Matroska, or no Cues: none.
    #[test]
    fn a_file_without_cues_has_none() {
        assert_eq!(
            read_cues(&mut reader(b"not a matroska file")).unwrap(),
            None
        );
        let ebml = el(EBML, &el(0x4282, b"matroska"));
        let mut file = ebml.clone();
        file.extend(el(SEGMENT, &el(CLUSTER, &[0; 16])));
        assert_eq!(read_cues(&mut reader(&file)).unwrap(), None);
    }

    /// Sizes in every length, and the unknown size.
    #[test]
    fn element_sizes_read_every_length() {
        assert_eq!(element_size(&[0x81]), Some((Some(1), 1)));
        assert_eq!(element_size(&[0x40, 0x02]), Some((Some(2), 2)));
        assert_eq!(
            element_size(&[0x01, 0, 0, 0, 0, 0, 0x01, 0x00]),
            Some((Some(256), 8))
        );
        assert_eq!(element_size(&[0xff]), Some((None, 1)));
        assert_eq!(
            element_size(&[0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            Some((None, 8))
        );
        assert_eq!(element_id(&[0x1A, 0x45, 0xDF, 0xA3]), Some((EBML, 4)));
        assert_eq!(element_id(&[0xBB]), Some((CUE_POINT, 1)));
    }
}
