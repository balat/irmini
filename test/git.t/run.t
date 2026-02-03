Git Interoperability - bidirectional compatibility with Git

  $ export TERM=dumb
  $ chmod +x normalize

Irmin to Git - verify git can read irmin-created content:

  $ mkdir irmin-repo
  $ cd irmin-repo
  $ irmin init . | sed 's/at .*/at PATH/'
  ✓ Initialised Git repository at PATH

  $ irmin set README.md '# Hello World' -m 'Initial commit' | ../normalize
  ✓ HASH
  $ irmin set src/main.ml 'let () = ()' -m 'Add source' | ../normalize
  ✓ HASH
  $ irmin del README.md -m 'Remove readme' | ../normalize
  ✓ HASH
  $ irmin checkout -c feature | sed 's/branch .*/branch BRANCH/'
  ✓ Created branch BRANCH

Git reads irmin commits:

  $ git log --oneline | head -3 | ../normalize
  HASH Remove readme
  HASH Add source
  HASH Initial commit

Git reads irmin content:

  $ git show HEAD:src/main.ml
  let () = ()

Git sees irmin branches:

  $ git branch
    feature
  * main

Git to Irmin - verify irmin can read git-created content:

  $ cd ..
  $ mkdir git-repo
  $ cd git-repo
  $ git init -q
  $ git config user.email "test@example.com"
  $ git config user.name "Test User"
  $ mkdir -p src
  $ echo 'print("hello")' > src/app.py
  $ git add src/app.py
  $ git commit -q -m 'Initial commit from git'

Irmin reads git content:

  $ irmin get src/app.py
  print("hello")

  $ irmin list
  src/

  $ irmin list src/
  app.py

  $ irmin tree
  src/
    app.py

Irmin reads git commits:

  $ irmin log | ../normalize
  HASH Test User <test@example.com>
      Initial commit from git
  
  


