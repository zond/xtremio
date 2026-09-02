import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/widgets/content_type_label.dart';

void main() {
  test('known types get their plural, unknown ones are capitalised', () {
    expect(contentTypeLabel('movie'), 'Movies');
    expect(contentTypeLabel('series'), 'Series');
    expect(contentTypeLabel('channel'), 'Channels');
    expect(contentTypeLabel('tv'), 'TV');
    expect(contentTypeLabel('anime'), 'Anime');
    expect(contentTypeLabel(''), '');
  });

  test('capitalise only touches the first letter', () {
    expect(capitalise('genre'), 'Genre');
    expect(capitalise('IMDb'), 'IMDb');
    expect(capitalise(''), '');
  });
}
