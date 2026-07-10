# How to start with previous versions of HAL2

Today, when creating a new project with **STM32CubeMX2**, the tool uses the latest packs available on the public server. However, an older pack version might be required for a project. The provided script makes it possible to start the latest version of **STM32CubeMX2** with **STM32C5 2.0.0 packs**.

This document describes how to use the provided script.

## Supported use case

A developer uses **STM32CubeMX2 1.0.0 or 1.0.1** with **STM32C5 2.0.0 packs** to create and maintain a project. When **STM32C5 2.1.0 packs** become available, **STM32CubeMX2** automatically uses them.

The same developer, or another developer, might want to use **STM32CubeMX2 1.1.0** to benefit from the latest delivered features, while still creating projects with **STM32C5 2.0.0 packs** because **STM32C5 2.1.0 packs** are not suitable for a specific reason. The script in this document allows that.

## Warning to read before starting

As long as you want to continue creating projects with **STM32C5 2.0.0 packs**, avoid the following actions:

- Using the Refresh button in the Pack Manager view
- Enabling pack synchronization from the **STM32CubeMX2** preference settings
- **STM32C5+** packs are evolutions of **STM32C5** packs. If you have installed **STM32C5+** packs, the script will remove them.


## 1. Get the script

The script `sync_pidx` is available in the GitHub repository **STMicroelectronics - STM32 Hotspot**.

One script available by OS :

- `windows_sync_pidx.sh` for Windows
- `ubuntu_sync_pidx.sh` for Linux
- `mac_sync_pidx.sh` for macOS

The txt file used by the script :

- `STMicroelectronics.pidx.txt` as the reference file for the packs to be used

## 2. Run the script

- Download the script and the txt file in a folder of your choice
- Open a terminal in the folder where the script and the txt file are located
- Run the script corresponding to your OS:
  - For Windows, with a Git Bash or WSL terminal, run `./windows_sync_pidx.sh`
  - For Linux, with a terminal, run `./ubuntu_sync_pidx.sh`
  - For macOS, with a terminal, run `./mac_sync_pidx.sh`

## 3. Status report

At the end of the script execution, the terminal displays a status report. The report provides the following information:

- `PIDX packs`: Number of packs that the reference PIDX file defines
- `Existing packs`: Number of packs or metadata detected on the local machine before synchronization
- `Packs removed`: Number of packs removed from the local machine because they do not match the reference PIDX file content
- `Packs installed`: Number of missing packs installed to match the reference PIDX file content
- `Packs already OK`: Number of packs already installed with the expected version, so no action is required
- `Packs skipped`: Number of pack operations skipped or not completed successfully, typically because of an installation or removal failure
- `NO_REMOVE`: Indicates whether pack removal is disabled during script execution
- `DRY_RUN`: Indicates whether the script runs in simulation mode without applying actual changes
- `Total duration`: Total script execution time

The message `[YYYY-MM-DD HH:MM:SS] Synchronization completed.` indicates that the script has completed successfully.

## 4. Launch STM32CubeMX2

After the script execution, launch **STM32CubeMX2** and create a new project.

The tool will use the packs defined in the reference file `STMicroelectronics.pidx.txt`, corresponding to **STM32C5 2.0.0 packs**, to create new projects.
