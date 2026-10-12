"""Wait for an app-owned backend's parent without sending Windows signals."""

import os
import errno
import select
import sys
import time


def wait_for_parent_exit(pid, interval=1.0):
    if pid <= 0:
        raise ValueError("parent PID must be positive")
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel.WaitForSingleObject.restype = wintypes.DWORD
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        # SYNCHRONIZE is sufficient to wait. Retain the handle so PID reuse
        # cannot accidentally attach this backend to an unrelated process.
        handle = kernel.OpenProcess(0x00100000, False, pid)
        if not handle:
            error = ctypes.get_last_error()
            if error == 87:  # ERROR_INVALID_PARAMETER: PID no longer exists
                return
            raise ctypes.WinError(error)
        try:
            result = kernel.WaitForSingleObject(handle, 0xFFFFFFFF)
            if result != 0:  # WAIT_OBJECT_0
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            kernel.CloseHandle(handle)
    else:
        if hasattr(os, "pidfd_open"):
            try:
                fd = os.pidfd_open(pid)
            except ProcessLookupError:
                return
            except OSError as exc:
                if exc.errno not in (errno.ENOSYS, errno.EINVAL, errno.EPERM, errno.EACCES):
                    raise
            else:
                try:
                    poller = select.poll()
                    poller.register(fd, select.POLLIN)
                    poller.poll()
                    return
                finally:
                    os.close(fd)
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            except PermissionError:
                pass
            time.sleep(interval)
