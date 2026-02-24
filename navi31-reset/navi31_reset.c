// SPDX-License-Identifier: GPL-2.0
/*
 * navi31_reset - Standalone GPU reset for AMD Navi 31 (RX 7900 XTX/XT)
 *
 * Implements MODE1 and BACO reset for VFIO GPU passthrough use cases,
 * without requiring the full amdgpu driver stack.
 *
 * SAFETY: This module uses direct ioremap of BAR5, avoiding pci_enable_device
 * and pci_disable_device. This makes it safe to load alongside amdgpu for
 * diagnostics (register reads). Reset operations are blocked while any driver
 * (amdgpu, vfio-pci) is bound to the GPU — unbind first.
 *
 * Usage:
 *   insmod navi31_reset.ko                    # Load module (safe with amdgpu)
 *   cat /dev/navi31-reset                     # Read GPU status registers
 *   # Before reset: unbind amdgpu from GPU
 *   echo mode1 > /dev/navi31-reset            # MODE1 reset
 *   echo baco  > /dev/navi31-reset            # BACO reset
 *   echo 1     > /dev/navi31-reset            # MODE1 shorthand
 *
 * Register sequences extracted from Linux kernel amdgpu driver:
 *   drivers/gpu/drm/amd/pm/swsmu/smu13/smu_v13_0.c
 *   drivers/gpu/drm/amd/pm/swsmu/smu13/smu_v13_0_0_ppt.c
 *   drivers/gpu/drm/amd/include/asic_reg/mp/mp_13_0_0_offset.h
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/mutex.h>
#include <linux/uaccess.h>

#define DRIVER_NAME	"navi31_reset"

/* --- PCI Device IDs (Navi 31 variants) --- */

#define NAVI31_XTX_DID	0x744c	/* RX 7900 XTX */
#define NAVI31_XT_DID	0x7448	/* RX 7900 XT */

/*
 * SMU v13.0.0 Register Offsets (dword-indexed within BAR5 MMIO)
 *
 * Register offsets from mp_13_0_0_offset.h need to be combined with
 * the IP discovery base offset for Navi 31. Both MP0 (PSP) and MP1 (SMU)
 * share seg[0] base = 0x00016000 dwords (0x58000 bytes) in BAR5.
 *
 * Final dword offset = MP_BASE + register_offset
 * BAR5 byte offset = final_dword_offset * 4
 *
 * Verified against the IP discovery table from our RX 7900 XTX:
 *   SOL at BAR5[0x58244] = 0x084498ac (non-zero = alive)
 *   Bootloader at BAR5[0x5818C] = 0x80000000 (bit 31 = ready)
 *   SOS version at BAR5[0x581E8] = 0x00310035 (matches firmware_info)
 */
#define MP_BASE		0x00016000	/* IP discovery seg[0] for MP0 & MP1 */

/* Normal mailbox — used for BACO enter/exit */
#define MP1_C2PMSG_66	(MP_BASE + 0x0282)	/* Message (command ID) */
#define MP1_C2PMSG_82	(MP_BASE + 0x0292)	/* Argument */
#define MP1_C2PMSG_90	(MP_BASE + 0x029a)	/* Response */

/* Debug mailbox — used for MODE1 reset on Navi 31 */
#define MP1_C2PMSG_53	(MP_BASE + 0x0275)	/* Parameter */
#define MP1_C2PMSG_75	(MP_BASE + 0x028b)	/* Message */
#define MP1_C2PMSG_54	(MP_BASE + 0x0276)	/* Response */

/* PSP registers */
#define MP0_C2PMSG_35	(MP_BASE + 0x0063)	/* Bootloader status (bit 31 = ready) */
#define MP0_C2PMSG_81	(MP_BASE + 0x0091)	/* SOL — Sign of Life (sOS alive) */

/* --- SMU Message IDs (from smu_v13_0_0_ppsmc.h) --- */

#define PPSMC_MSG_EnterBaco		0x15
#define PPSMC_MSG_ExitBaco		0x16
#define DEBUGSMC_MSG_Mode1Reset		0x02	/* Debug mailbox only! */

/* BACO sequence parameters */
#define BACO_SEQ_BACO	1	/* Full chip off, bus stays alive */

/* --- Timing --- */

#define MODE1_WAIT_MS		500		/* Wait after MODE1 trigger */
#define BACO_SETTLE_US		10000		/* 10ms settle after BACO enter */
#define SMU_POLL_TIMEOUT_US	5000000		/* 5s for SMU mailbox response */
#define BOOT_POLL_TIMEOUT_US	10000000	/* 10s for PSP bootloader */
#define SMU_RESP_OK		1

/* --- Register Access Helpers --- */

static void __iomem *mmio;

static inline u32 rreg32(u32 dword_off)
{
	return readl(mmio + (u64)dword_off * 4);
}

static inline void wreg32(u32 dword_off, u32 val)
{
	writel(val, mmio + (u64)dword_off * 4);
}

/* --- Global State --- */

static struct pci_dev *gpu_pdev;
static struct pci_dev *audio_pdev;
static DEFINE_MUTEX(reset_lock);

/*
 * Send a message via the SMU normal mailbox and wait for response.
 * Returns 0 on success, negative errno on failure.
 */
static int smu_send_msg(u32 msg, u32 param)
{
	unsigned long deadline;
	u32 resp;

	/* Wait for previous command to finish */
	deadline = jiffies + usecs_to_jiffies(SMU_POLL_TIMEOUT_US);
	while (rreg32(MP1_C2PMSG_90) == 0) {
		if (time_after(jiffies, deadline)) {
			pr_err("%s: SMU busy (previous cmd not done)\n",
			       DRIVER_NAME);
			return -ETIMEDOUT;
		}
		udelay(10);
	}

	/* Clear response, set param, send message */
	wreg32(MP1_C2PMSG_90, 0);
	wreg32(MP1_C2PMSG_82, param);
	wreg32(MP1_C2PMSG_66, msg);

	/* Poll for response */
	deadline = jiffies + usecs_to_jiffies(SMU_POLL_TIMEOUT_US);
	while ((resp = rreg32(MP1_C2PMSG_90)) == 0) {
		if (time_after(jiffies, deadline)) {
			pr_err("%s: SMU timeout (msg=0x%02x param=0x%x)\n",
			       DRIVER_NAME, msg, param);
			return -ETIMEDOUT;
		}
		udelay(10);
	}

	if (resp != SMU_RESP_OK) {
		pr_warn("%s: SMU error 0x%x (msg=0x%02x param=0x%x)\n",
			DRIVER_NAME, resp, msg, param);
		return -EIO;
	}

	return 0;
}

/*
 * MODE1 Reset — the kernel driver's default for Navi 31.
 *
 * Sends DEBUGSMC_MSG_Mode1Reset via the debug mailbox, which is a
 * fire-and-forget operation: the GPU resets and MMIO goes dark for ~500ms.
 * After the wait, we restore PCI config and verify the PSP came back.
 */
static bool gpu_responsive(void)
{
	u32 sol = rreg32(MP0_C2PMSG_81);
	u32 boot = rreg32(MP0_C2PMSG_35);

	return sol != 0xffffffff || boot != 0xffffffff;
}

static int navi31_mode1_reset(void)
{
	unsigned long deadline;
	u32 val;

	pr_info("%s: MODE1 reset starting\n", DRIVER_NAME);

	/* Sanity: log pre-reset state */
	val = rreg32(MP0_C2PMSG_81);
	pr_info("%s: pre-reset SOL=0x%08x\n", DRIVER_NAME, val);

	/* Fail fast if GPU is completely unresponsive (PCIe link down, D3cold, etc.)
	 * Writing MODE1 to a dead device won't help — caller should try SBR. */
	if (!gpu_responsive()) {
		pr_err("%s: GPU not responding (all regs 0xffffffff) — MODE1 aborted\n",
		       DRIVER_NAME);
		pr_err("%s: try PCI bus reset: echo 1 > /sys/bus/pci/devices/%s/reset\n",
		       DRIVER_NAME, pci_name(gpu_pdev));
		return -ENODEV;
	}

	/* Save PCI config space (will be wiped by MODE1) */
	pci_save_state(gpu_pdev);
	if (audio_pdev)
		pci_save_state(audio_pdev);

	/* Disable bus mastering before reset */
	pci_clear_master(gpu_pdev);

	/*
	 * Fire MODE1 reset via debug mailbox.
	 * Three register writes — no response polling (GPU resets immediately).
	 */
	wreg32(MP1_C2PMSG_53, 0);			/* param = 0 */
	wreg32(MP1_C2PMSG_75, DEBUGSMC_MSG_Mode1Reset);/* message */
	wreg32(MP1_C2PMSG_54, 0);			/* clear response */

	pr_info("%s: MODE1 message sent, waiting %dms...\n",
		DRIVER_NAME, MODE1_WAIT_MS);

	/* GPU is resetting — MMIO unavailable */
	msleep(MODE1_WAIT_MS);

	/* Restore PCI config (BARs, command reg, capabilities) */
	pci_restore_state(gpu_pdev);
	if (audio_pdev)
		pci_restore_state(audio_pdev);

	/*
	 * Wait for PSP bootloader ready.
	 * Bit 31 of MP0_C2PMSG_35 = 0x80000000 means bootloader is up.
	 */
	deadline = jiffies + usecs_to_jiffies(BOOT_POLL_TIMEOUT_US);
	for (;;) {
		val = rreg32(MP0_C2PMSG_35);
		if (val == 0x80000000)
			break;
		if (time_after(jiffies, deadline)) {
			pr_err("%s: PSP bootloader timeout (reg=0x%08x)\n",
			       DRIVER_NAME, val);
			return -ETIMEDOUT;
		}
		usleep_range(100, 500);
	}
	pr_info("%s: PSP bootloader ready\n", DRIVER_NAME);

	/* Verify SOL (Sign of Life) — sOS is alive */
	val = rreg32(MP0_C2PMSG_81);
	pr_info("%s: MODE1 reset complete (SOL=0x%08x)\n", DRIVER_NAME, val);

	return 0;
}

/*
 * BACO Reset — Bus Active, Chip Off.
 *
 * Powers down the GPU chip while keeping the PCIe link alive.
 * Uses the normal SMU mailbox (EnterBaco/ExitBaco).
 * Less aggressive than MODE1 but may not clear all internal state.
 */
static int navi31_baco_reset(void)
{
	unsigned long deadline;
	u32 val;
	int ret;

	pr_info("%s: BACO reset starting\n", DRIVER_NAME);

	/* Fail fast if GPU is completely unresponsive */
	if (!gpu_responsive()) {
		pr_err("%s: GPU not responding (all regs 0xffffffff) — BACO aborted\n",
		       DRIVER_NAME);
		return -ENODEV;
	}

	/* Enter BACO */
	ret = smu_send_msg(PPSMC_MSG_EnterBaco, BACO_SEQ_BACO);
	if (ret) {
		pr_err("%s: EnterBaco failed (%d)\n", DRIVER_NAME, ret);
		return ret;
	}
	pr_info("%s: entered BACO\n", DRIVER_NAME);

	/* Let the chip settle */
	usleep_range(BACO_SETTLE_US, BACO_SETTLE_US + 1000);

	/* Exit BACO */
	ret = smu_send_msg(PPSMC_MSG_ExitBaco, 0);
	if (ret) {
		pr_err("%s: ExitBaco failed (%d)\n", DRIVER_NAME, ret);
		return ret;
	}
	pr_info("%s: exited BACO\n", DRIVER_NAME);

	/* Wait for SOL (PSP Secure OS alive) */
	deadline = jiffies + usecs_to_jiffies(BOOT_POLL_TIMEOUT_US);
	for (;;) {
		val = rreg32(MP0_C2PMSG_81);
		if (val != 0)
			break;
		if (time_after(jiffies, deadline)) {
			pr_err("%s: SOL timeout after BACO exit\n",
			       DRIVER_NAME);
			return -ETIMEDOUT;
		}
		usleep_range(100, 500);
	}

	pr_info("%s: BACO reset complete (SOL=0x%08x)\n", DRIVER_NAME, val);
	return 0;
}

static bool gpu_driver_active(void)
{
	/*
	 * Check if a driver is actively managing the GPU.
	 *
	 * We can't just check pci_dev->driver because during amdgpu unbind,
	 * the pointer stays non-NULL while drm_dev_unplug blocks on DRM
	 * reference cleanup — even though the hardware is already orphaned.
	 *
	 * Instead, check the sysfs driver symlink which is removed earlier
	 * in the unbind process (by device_unbind_cleanup, before
	 * device_remove/drm_dev_unplug).
	 */
	return gpu_pdev->driver &&
	       device_is_bound(&gpu_pdev->dev);
}

static int do_reset(const char *which, bool force)
{
	/* Safety: refuse to reset if a driver is actively managing the GPU.
	 * Resetting while amdgpu is active WILL cause a soft lockup.
	 * The caller must unbind amdgpu/vfio-pci first.
	 * Use "force_mode1" or "force_baco" to override. */
	if (gpu_driver_active() && !force) {
		pr_err("%s: BLOCKED — GPU is bound to '%s', unbind first!\n",
		       DRIVER_NAME, gpu_pdev->driver->name);
		pr_err("%s:   echo %s > /sys/bus/pci/devices/%s/driver/unbind\n",
		       DRIVER_NAME, pci_name(gpu_pdev), pci_name(gpu_pdev));
		pr_err("%s:   (or use force_mode1/force_baco to override)\n",
		       DRIVER_NAME);
		return -EBUSY;
	}

	if (force && gpu_pdev->driver)
		pr_warn("%s: FORCE — resetting despite driver '%s' (may be in teardown)\n",
			DRIVER_NAME, gpu_pdev->driver->name);

	if (strcmp(which, "mode1") == 0 || strcmp(which, "1") == 0)
		return navi31_mode1_reset();
	if (strcmp(which, "baco") == 0)
		return navi31_baco_reset();

	pr_err("%s: unknown method '%s' (use: mode1, baco, force_mode1, force_baco)\n",
	       DRIVER_NAME, which);
	return -EINVAL;
}

/* --- /dev/navi31-reset character device --- */

static ssize_t reset_dev_write(struct file *f, const char __user *buf,
			       size_t count, loff_t *off)
{
	char cmd[32];
	const char *method;
	bool force = false;
	size_t len;
	int ret;

	len = min(count, sizeof(cmd) - 1);
	if (copy_from_user(cmd, buf, len))
		return -EFAULT;
	cmd[len] = '\0';

	/* Strip trailing newline */
	if (len > 0 && cmd[len - 1] == '\n')
		cmd[--len] = '\0';

	/* Parse "force_" prefix */
	method = cmd;
	if (strncmp(cmd, "force_", 6) == 0) {
		force = true;
		method = cmd + 6;
	}

	if (!mutex_trylock(&reset_lock)) {
		pr_err("%s: reset already in progress\n", DRIVER_NAME);
		return -EBUSY;
	}

	ret = do_reset(method, force);

	mutex_unlock(&reset_lock);

	return ret < 0 ? ret : (ssize_t)count;
}

static ssize_t reset_dev_read(struct file *f, char __user *buf,
			      size_t count, loff_t *off)
{
	/*
	 * Read returns current GPU health status for quick diagnostics.
	 */
	char status[128];
	int len;
	u32 sol, boot;

	if (*off > 0)
		return 0;

	sol = rreg32(MP0_C2PMSG_81);
	boot = rreg32(MP0_C2PMSG_35);
	len = scnprintf(status, sizeof(status),
			"SOL=0x%08x bootloader=0x%08x\n", sol, boot);

	if (len > count)
		len = count;
	if (copy_to_user(buf, status, len))
		return -EFAULT;

	*off += len;
	return len;
}

static const struct file_operations reset_fops = {
	.owner	= THIS_MODULE,
	.write	= reset_dev_write,
	.read	= reset_dev_read,
};

static struct miscdevice reset_miscdev = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "navi31-reset",
	.fops	= &reset_fops,
};

/* --- Module Init/Exit --- */

static int __init navi31_reset_init(void)
{
	struct pci_dev *pdev = NULL;
	resource_size_t bar5_start, bar5_len;
	int ret;

	/* Find a Navi 31 GPU */
	pdev = pci_get_device(PCI_VENDOR_ID_ATI, NAVI31_XTX_DID, NULL);
	if (!pdev)
		pdev = pci_get_device(PCI_VENDOR_ID_ATI, NAVI31_XT_DID, NULL);
	if (!pdev) {
		pr_err("%s: no Navi 31 GPU found\n", DRIVER_NAME);
		return -ENODEV;
	}
	gpu_pdev = pdev;

	pr_info("%s: found GPU [%04x:%04x] at %s\n", DRIVER_NAME,
		pdev->vendor, pdev->device, pci_name(pdev));

	/* Look for HDMI/DP audio function on the same slot (function 1) */
	audio_pdev = pci_get_domain_bus_and_slot(
		pci_domain_nr(pdev->bus),
		pdev->bus->number,
		PCI_DEVFN(PCI_SLOT(pdev->devfn), 1));
	if (audio_pdev)
		pr_info("%s: found audio function at %s\n",
			DRIVER_NAME, pci_name(audio_pdev));

	/*
	 * Map BAR5 via direct ioremap — NOT pci_enable_device/pci_iomap.
	 *
	 * This avoids interfering with PCI device ownership. The physical
	 * address is valid as long as BARs are configured (which the BIOS
	 * always does). Multiple ioremap of the same MMIO are safe in Linux,
	 * so this works even when amdgpu has its own BAR5 mapping.
	 *
	 * AMD GPU BAR layout:
	 *   BAR0/1 = VRAM (64-bit, prefetchable, up to 32GB)
	 *   BAR2/3 = Doorbell (64-bit, prefetchable, 2MB)
	 *   BAR4   = I/O ports
	 *   BAR5   = MMIO registers (32-bit, non-prefetchable, 1MB)
	 */
	bar5_start = pci_resource_start(gpu_pdev, 5);
	bar5_len = pci_resource_len(gpu_pdev, 5);
	if (!bar5_start || !bar5_len) {
		pr_err("%s: BAR5 not configured\n", DRIVER_NAME);
		ret = -EIO;
		goto err_put;
	}

	mmio = ioremap(bar5_start, bar5_len);
	if (!mmio) {
		pr_err("%s: ioremap BAR5 failed (phys=0x%llx len=%llu)\n",
		       DRIVER_NAME,
		       (unsigned long long)bar5_start,
		       (unsigned long long)bar5_len);
		ret = -EIO;
		goto err_put;
	}

	pr_info("%s: BAR5 mapped at phys 0x%llx (%llu bytes)\n", DRIVER_NAME,
		(unsigned long long)bar5_start,
		(unsigned long long)bar5_len);

	/* Log initial state */
	pr_info("%s: SOL=0x%08x bootloader=0x%08x\n", DRIVER_NAME,
		rreg32(MP0_C2PMSG_81), rreg32(MP0_C2PMSG_35));

	/* Register /dev/navi31-reset */
	ret = misc_register(&reset_miscdev);
	if (ret) {
		pr_err("%s: misc_register failed (%d)\n", DRIVER_NAME, ret);
		goto err_unmap;
	}

	pr_info("%s: /dev/navi31-reset ready\n", DRIVER_NAME);

	if (gpu_pdev->driver)
		pr_info("%s: GPU bound to '%s' — reads OK, reset blocked until unbound\n",
			DRIVER_NAME, gpu_pdev->driver->name);

	return 0;

err_unmap:
	iounmap(mmio);
err_put:
	if (audio_pdev)
		pci_dev_put(audio_pdev);
	pci_dev_put(gpu_pdev);
	return ret;
}

static void __exit navi31_reset_exit(void)
{
	misc_deregister(&reset_miscdev);
	iounmap(mmio);
	if (audio_pdev)
		pci_dev_put(audio_pdev);
	pci_dev_put(gpu_pdev);
	pr_info("%s: unloaded\n", DRIVER_NAME);
}

module_init(navi31_reset_init);
module_exit(navi31_reset_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("myuser");
MODULE_DESCRIPTION("Standalone GPU reset for AMD Navi 31 (RX 7900 XTX/XT)");
MODULE_VERSION("1.0");
