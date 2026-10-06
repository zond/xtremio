import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/update/install_room.dart';

void main() {
  const mib = 1024 * 1024;

  group("Android's low-storage reserve", () {
    test('is 5% of the volume on a small one', () {
      expect(
        UpdateRoom.lowStorageReserve(
          const DataVolumeRoom(freeBytes: 0, totalBytes: 4000000000),
        ),
        200000000,
      );
    });

    test('is capped at 500 MiB on a large one', () {
      expect(
        UpdateRoom.lowStorageReserve(
          const DataVolumeRoom(freeBytes: 0, totalBytes: 64000000000),
        ),
        500 * mib,
      );
    });

    test("follows the device's own settings where it could read them", () {
      expect(
        UpdateRoom.lowStorageReserve(
          const DataVolumeRoom(
            freeBytes: 0,
            totalBytes: 4000000000,
            thresholdPercent: 10,
          ),
        ),
        400000000,
      );
      expect(
        UpdateRoom.lowStorageReserve(
          const DataVolumeRoom(
            freeBytes: 0,
            totalBytes: 64000000000,
            thresholdMaxBytes: 100 * mib,
          ),
        ),
        100 * mib,
      );
    });

    test('is the cap on a volume whose size is unknown', () {
      expect(
        UpdateRoom.lowStorageReserve(
          const DataVolumeRoom(freeBytes: 0, totalBytes: 0),
        ),
        500 * mib,
      );
    });
  });

  group('what an update needs', () {
    // A 50 MB APK on a 4 GB volume: the reserve is 200 MB.
    DataVolumeRoom volume(int free) =>
        DataVolumeRoom(freeBytes: free, totalBytes: 4000000000);

    test('before the download: the download, two more, and the reserve', () {
      final room = UpdateRoom.forApk(
        apkBytes: 50000000,
        volume: volume(330000000),
        downloaded: false,
      );
      expect(room.neededBytes, 350000000);
      // What the Chromecast refused, refused; what it took, taken.
      expect(room.fits, isFalse);
      expect(
        UpdateRoom.forApk(
          apkBytes: 50000000,
          volume: volume(500000000),
          downloaded: false,
        ).fits,
        isTrue,
      );
    });

    test('before the install: two APKs and the reserve', () {
      final room = UpdateRoom.forApk(
        apkBytes: 50000000,
        volume: volume(300000000),
        downloaded: true,
      );
      expect(room.neededBytes, 300000000);
      expect(room.fits, isTrue);
      expect(
        UpdateRoom.forApk(
          apkBytes: 50000000,
          volume: volume(299999999),
          downloaded: true,
        ).fits,
        isFalse,
      );
    });
  });

  test('the channel answer reads back, and no free space is no answer', () {
    final room = DataVolumeRoom.fromMap({
      'freeBytes': 1,
      'totalBytes': 2,
      'thresholdPercent': 3,
      'thresholdMaxBytes': 4,
    })!;
    expect(
      [
        room.freeBytes,
        room.totalBytes,
        room.thresholdPercent,
        room.thresholdMaxBytes,
      ],
      [1, 2, 3, 4],
    );
    final unset = DataVolumeRoom.fromMap({'freeBytes': 1, 'totalBytes': 2})!;
    expect(unset.thresholdPercent, isNull);
    expect(unset.thresholdMaxBytes, isNull);
    expect(DataVolumeRoom.fromMap({'totalBytes': 2}), isNull);
    expect(DataVolumeRoom.fromMap(null), isNull);
  });
}
