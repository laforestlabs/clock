// This device's own position: the setup wizard's GPS source.
//
// A mirror is installed where the phone is standing, so "use this device's
// location" is the least typing an owner can do. Geolocator covers the
// platforms the app runs on (Android, iOS, macOS, Windows, Linux through
// GeoClue, web), and every failure it can report is a sentence an owner can
// act on rather than an exception dump.
//
// This is the only file that imports geolocator, so the platform plugins stay
// behind one seam and the picker that calls it stays widget-testable.

import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// A position failure, worded as a sentence the setup screen can show.
class DeviceLocationException implements Exception {
  const DeviceLocationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// This device's own position, for the wizard's GPS source.
///
/// Throws [DeviceLocationException] with an actionable sentence: services off,
/// permission denied or permanently denied, a timed-out fix, or a host with no
/// location provider (a desktop without GeoClue).
Future<LatLng> currentDeviceLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const DeviceLocationException(
          'Location services are turned off on this device.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // Ask once: the first tap is the owner telling us what they want.
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const DeviceLocationException(
          'Location permission is blocked; allow it in the device settings.');
    }
    if (permission == LocationPermission.denied) {
      throw const DeviceLocationException('Location permission was denied.');
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return LatLng(position.latitude, position.longitude);
  } on DeviceLocationException {
    rethrow;
  } on TimeoutException {
    throw const DeviceLocationException(
        'Timed out waiting for a position fix.');
  } catch (e) {
    // Includes MissingPluginException on a host with no provider.
    throw DeviceLocationException('Could not get a position: $e');
  }
}
