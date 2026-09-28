"""Rootless Wi-Fi RemotePairing tunnel to the Apple TV (pymobiledevice3 userspace stack).

pymobiledevice3's --userspace path only discovers devices through usbmux (USB). This module
patches the provider factory so the same userspace tunnel is built straight from the TV's
_remotepairing._tcp service over Wi-Fi, using the pair record in ~/.pymobiledevice3.
"""
import asyncio
import os

from pymobiledevice3.remote import tunnel_service, userspace_tunnel

TV_UDID = os.environ.get("TV_UDID")  # None: the first paired Apple TV found over bonjour


async def _wifi_provider(serial, autopair, remotepairing_fallback=True):
    services = await tunnel_service.get_remote_pairing_tunnel_services(udid=TV_UDID, bonjour_timeout=8)
    if not services:
        # Bonjour answers are sometimes missed; the TV keeps the same address and port.
        host = os.environ.get("TV_IP")
        if not host:
            raise RuntimeError("Apple TV not found over bonjour; set TV_IP to connect directly")
        port = int(os.environ.get("TV_RP_PORT", "49152"))
        udid = TV_UDID or next(iter(i for i, _, _ in tunnel_service.iter_remote_pair_records_by_identifier()), None)
        return await tunnel_service.create_core_device_tunnel_service_using_remotepairing(udid, host, port), None
    for extra in services[1:]:
        try:
            await extra.close()
        except Exception:
            pass
    return services[0], None


userspace_tunnel._create_no_root_tunnel_provider = _wifi_provider


async def open_tunnel():
    t = userspace_tunnel.UserspaceRsdTunnel(serial=TV_UDID)
    rsd = await t.aopen()
    return t, rsd
