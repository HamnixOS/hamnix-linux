#!/usr/bin/env python3
# Print a free TCP port. Used by tests/linux/hpm_kernel_http.sh so two runs of
# it can be in flight at once without colliding on a fixed number.
import socket

s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
