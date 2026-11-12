This change is about to be pushed to a pull-request branch. Review the whole change, not just its latest commit.

The convention files supplied with this review are our review punch list. Each item in them is a class of bug that a
past pull request shipped into review and that took extra review rounds to find. Check the change against every item
that applies to the changed code, and when one place in the change has a bug of a class, look for the same class in the
rest of the change.

Severity, as this repository uses it: `critical` breaks things or opens a security hole, `major` is wrong behaviour
under realistic conditions, `minor` is a real bug that will rarely surface but must still be fixed before merge,
`nitpick` is style or naming.
