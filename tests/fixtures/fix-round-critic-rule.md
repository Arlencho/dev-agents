## Review rounds above 1: targeted fixtures only

In a review round above 1, re-run only the fixtures of the findings being closed plus one regression check you name. Do not re-run every fixture from earlier rounds unless the diff touches their code.

Scope the verdict the same way. Open the round with one line per earlier finding, ADDRESSED or NOT ADDRESSED, each with file:line evidence; an attempt that does not hold is NOT ADDRESSED. A new finding counts for the verdict only when it sits in the fix diff, breakage the fix itself introduced included. A new finding outside the fix diff is filed as an issue on the product repo and named in the review comment under Out of scope: it does not change the verdict and does not extend the loop. The exception is the one every verdict list already carries: BLOCK-ESCALATE for a defect that must not wait, and on a Tier A surface a money, identity or security defect is always that one.
