// What the firmware a mirror runs says about the firmware this app ships, and
// the upload that closes the gap.
//
// The comparison exists so the app can offer an update the moment it connects
// to a mirror running something older (see ui/firmware_prompt.dart). The
// version compared against is read from the image that would be uploaded, not
// from a number written down somewhere else, so "older" always means "the
// bytes this app can replace it with are newer" (services/bundled_firmware.dart).
import 'mirror_ble_status.dart';

/// Compare two app-image versions, most significant field first.
///
/// Returns a negative number when [a] is older than [b], zero when they name
/// the same version, and a positive number when [a] is newer. Versions are
/// dotted decimal (`0.2.33`) and are compared field by field, numerically
/// rather than as text, so `0.2.9` is older than `0.2.10`.
///
/// A missing field counts as zero, so `0.2` equals `0.2.0`. A field that is
/// not a number also counts as zero: this comparator orders what it can, while
/// [firmwareUpdateAvailable] is the one that refuses a version it cannot read.
int compareFirmwareVersions(String a, String b) {
  final pa = a.split('.');
  final pb = b.split('.');
  final fields = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < fields; i++) {
    final va = i < pa.length ? (int.tryParse(pa[i]) ?? 0) : 0;
    final vb = i < pb.length ? (int.tryParse(pb[i]) ?? 0) : 0;
    if (va != vb) return va < vb ? -1 : 1;
  }
  return 0;
}

/// Whether a mirror reporting [deviceVersion] should be offered the update to
/// [bundledVersion]: it is older, and both versions are known.
///
/// A mirror on the same version, or on a newer one, is left alone: this app
/// cannot improve either, and two builds under one version is exactly what the
/// firmware's own version rule exists to prevent. A version that is not
/// dotted decimal is unknown rather than old - an app that cannot read the
/// version must not claim to know which of the two is newer.
bool firmwareUpdateAvailable({
  required String deviceVersion,
  required String bundledVersion,
}) {
  if (!_isVersion(deviceVersion) || !_isVersion(bundledVersion)) return false;
  return compareFirmwareVersions(deviceVersion, bundledVersion) < 0;
}

/// Whether [v] is dotted decimal (`0.2.33`), the shape the firmware's own
/// version rule produces.
bool _isVersion(String v) =>
    v.isNotEmpty && v.split('.').every((f) => int.tryParse(f) != null);

/// The byte offset a [total]-byte image should resume from.
int firmwareResumeOffset(BleOtaStatus? status, int total) {
  if (status == null || !status.active || status.total != total) return 0;
  return status.written > 0 ? status.written : 0;
}
