// The test bundle's load-time hook. There is nothing to call from here: the constructor in bootstrap.c runs by itself
// when xctest loads the bundle, before the first test, whether the whole suite runs or a single test does.
#pragma once
