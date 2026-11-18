// Umbrella header exposing libmdr's C ABI (and the macOS Bluetooth backend) to Swift.
// The headers themselves live in the SonyHeadphonesClient submodule; see vendor/.
#pragma once

#include <mdr-c/Base.h>
#include <mdr-c/Connection.h>
#include <mdr-c/Headphones.h>
#include <mdr-bt/ConnectionMacOS.h>
