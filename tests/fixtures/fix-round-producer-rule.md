## Fix rounds: targeted tests only

In a fix round (a plan whose header or task names a round number above 1, or a FIX-ROUND header, or a fix suffix), run only the test file or test names that cover the code you touched, plus the failing tests the critic wrote. Do not run the full suite, do not run mutation checks, do not background a test run and wait on it. The full suite runs once, in the final round before merge, or in CI.
