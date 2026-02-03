Irmin CLI - content-addressed storage

  $ export TERM=dumb
  $ chmod +x normalize

Create a new repository:

  $ mkdir testrepo
  $ cd testrepo
  $ irmin init . | sed 's/at .*/at PATH/'
  ✓ Initialised Git repository at PATH

Check branches (initially empty):

  $ irmin branches

Add content:

  $ irmin set README.md '# Hello World' -m 'Initial commit' | ../normalize
  ✓ HASH

Get content back:

  $ irmin get README.md
  # Hello World

List paths:

  $ irmin list
  README.md

Show tree:

  $ irmin tree
  README.md

Show log:

  $ irmin log | ../normalize
  HASH irmin <irmin@local>
      Initial commit
  




JSON output mode:

  $ irmin get README.md -o json
  {"path":"README.md","content":"# Hello World"}

  $ irmin list -o json
  [{"name":"README.md","type":"file"}]

Add nested content:

  $ irmin set src/main.ml 'let () = ()' -m 'Add source' | ../normalize
  ✓ HASH

  $ irmin list
  README.md
  src/

  $ irmin list src/
  main.ml

  $ irmin tree
  README.md
  src/
    main.ml

Delete content:

  $ irmin del README.md -m 'Remove readme' | ../normalize
  ✓ HASH

  $ irmin list
  src/

Show commit history:

  $ irmin log -n 2 | ../normalize
  HASH irmin <irmin@local>
      Remove readme
  
  HASH irmin <irmin@local>
      Add source
  






Create and switch to a new branch:

  $ irmin checkout -c feature | sed 's/branch .*/branch BRANCH/'
  ✓ Created branch BRANCH

  $ irmin branches
    main
    feature

  $ irmin checkout main | sed 's/branch .*/branch BRANCH/'
  ✓ Switched to branch BRANCH
