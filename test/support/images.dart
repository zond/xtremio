/// Reading what an [Image] fetches and what it decodes.
///
/// Both questions have to see through a [ResizeImage]: `cacheWidth` and
/// `cacheHeight` are not kept on the widget, they are the wrapper
/// [DiskCachedImage.bounded] puts round its provider, so a test that looks
/// straight at `image.image` for a provider stops finding one the moment a
/// decode is bounded.
///
/// Flutter's own [NetworkImage] is still read here although nothing in
/// `lib/` builds one any more: a screen that went back to `Image.network`
/// should fail on the URL it fetches or the bound it names, not on a null
/// from this file.
library;

import 'package:flutter/material.dart';
import 'package:xtremio/core/core.dart';

/// What [image] is fetching, through the wrapper a bounded decode adds.
String? networkUrlOf(Image? image) => switch (image?.image) {
  ResizeImage(:final DiskCachedImage imageProvider) => imageProvider.url,
  ResizeImage(:final NetworkImage imageProvider) => imageProvider.url,
  DiskCachedImage(:final url) => url,
  NetworkImage(:final url) => url,
  _ => null,
};

/// The size [image] is decoded at, in physical pixels: null in the
/// dimension left to the source's own aspect, and null altogether when
/// nothing bounds the decode at all.
({int? width, int? height})? decodeOf(Image image) => switch (image.image) {
  ResizeImage(:final width, :final height) => (width: width, height: height),
  _ => null,
};
