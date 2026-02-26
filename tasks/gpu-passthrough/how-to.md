# How To

**Start gaming**: Click the "Overwatch" desktop shortcut. vm-overwatch stops services (ollama, openrgb, GDM), switches the GPU to vfio-pci, starts the VM, blanks the iGPU (monitor auto-switches to DP), and tunes CPU performance. Takes ~15s from click to Windows desktop.

**Stop gaming**: Shut down Windows from the Start menu. The `NotifyHostShutdown` scheduled task automatically sends a UDP timing signal to vm-overwatch on shutdown. vm-overwatch detects the shutdown, restores the GPU to amdgpu, unblanks the iGPU (monitor switches back to HDMI), and restarts all services.

**Monitor**: `journalctl -u vm-overwatch -f` for live logs. `vm-overwatch status` for a snapshot of GPU driver, VM state, iGPU, services, and CPU governor.
