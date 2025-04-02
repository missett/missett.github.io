# Reproducible Python Builds

Working on a client project recently, I was confronted with the vintage Terraform Plan output-

```
# aws_lambda_function.app_lambda will be updated in-place
~ resource "aws_lambda_function" "app_lambda" {
      id                             = "app-lambda-internal-qa"
    ~ last_modified                  = "2025-03-25T13:29:18.000+0000" -> (known after apply)
    ~ s3_object_version              = "El4G531bhb7eK0ygj6tUs2VpIlBwqS16" -> (known after apply)
    ~ source_code_hash               = "38193edcf343cfc86ad01649282af773" -> "69188a2295b615f7d264bdbc70f4905d"
      tags                           = {}
      # (28 unchanged attributes hidden)

      # (4 unchanged blocks hidden)
  }

# aws_s3_object.lambda_package will be updated in-place
~ resource "aws_s3_object" "lambda_package" {
      id                            = "lambda.zip"
    ~ source_hash                   = "38193edcf343cfc86ad01649282af773" -> "69188a2295b615f7d264bdbc70f4905d"
      tags                          = {}
    ~ version_id                    = "El4G531bhb7eK0ygj6tUs2VpIlBwqS16" -> (known after apply)
      # (24 unchanged attributes hidden)
  }
```

I hadn't changed any of the Python source code that formed the Lambda package to be deployed, so why should the hash of the Zip file have changed?

Let's rewind a little and clarify the exact setup we're talking about here. I have a Python code base that needs to be deployed as an AWS Lambda. To work around Lambda file size limits, we put the Zip into AWS S3 and configure the Lambda to point at the S3 object. Before all that, we need to create the Zip file from our `src` directory containing all our Python code, plus the associated dependencies for the project. I prefer to use a `makefile` to do this, so I can run the build system on my laptop when I'm debugging things. Here's an example of the `makefile` target I'm using to do this at the minute. Typing `make package.zip` is enough to get a build of our Lambda.

```
.venv:
    poetry install

%.zip: .venv
	mkdir -p $*.pkg
	cp -r .venv/lib/python3.12/site-packages/** $*.pkg
	cp -r src/** $*.pkg
	cd $*.pkg && zip -r -q $*.zip .
	mv $*.pkg/$*.zip $*.zip
```

- The target to create our zip archive will first make sure that all our dependencies are installed in .venv. Because we run our builds on GitHub Actions like good engineers, a fresh copy of our dependencies is downloaded every time. 
- Also good to know is the fact that file names do not affect the hash of a file.
- The %.zip target matches any invocation of make that ends with .zip, and $* within the definition uses the bit of text that % matched in the target name. So I can type `make alpha.zip` and `make bravo.zip` to get two zip files with my lambda code in them.

Let's examine the differences in a simple case. We'll delete the .venv directory each time we rebuild, to mimic our CI/CD build wherein separate builds download new copies of the dependencies every time.

```
 make alpha.zip
...
 md5sum alpha.zip
c720d19b5b1bd909dbf1e2b785358f18  alpha.zip
 rm -rf .venv
 
 make bravo.zip
...
 md5sum bravo.zip
c8c483c18c29b27cd098f3da494555ca  bravo.zip
  rm -rf .venv

 ls -@ -l -O -T *.zip
-rw-r--r--@ 1 ryan.missett  staff  - 50949616  1 Apr 10:41:13 2025 alpha.zip
	com.apple.provenance	      11
-rw-r--r--@ 1 ryan.missett  staff  - 50949616  1 Apr 10:41:44 2025 bravo.zip
	com.apple.provenance	      11
```

We can see that the two zip files differ in the created timestamp for a start. Because file attributes like modification time are stored in the file, this will affect the hash of the file. So let's start setting the timestamp of the file to be something consistent. We'll use the git log to determine the last time the `src` directory was modified. Something like this `touch -t $$(git log -1 --date=format:"%Y%m%d%H%M" --format="%ad" -- src) $*.zip`.

```
 md5sum alpha.zip
d67f05ce165d961e74d988a9e56a6404  alpha.zip
 md5sum bravo.zip
5b194e969d1e61a4335a986d050924d2  bravo.zip
 ls -@ -l -O -T *.zip
-rw-r--r--@ 1 ryan.missett  staff  - 50949616 28 Mar 15:22:00 2025 alpha.zip
	com.apple.provenance	      11
-rw-r--r--@ 1 ryan.missett  staff  - 50949616 28 Mar 15:22:00 2025 bravo.zip
	com.apple.provenance	      11
```

Nope, no good still. The attributes of the Zip archives match now, but the hashes are still different. Let's start comparing the contents of the archives to dig into this a little more.

```
 diff -y -s <(zipinfo alpha.zip) <(zipinfo bravo.zip)
...
drwxr-xr-x  3.0 unx        0 bx stor 25-Apr-01 10:51 astroid/ | drwxr-xr-x  3.0 unx        0 bx stor 25-Apr-01 10:52 astroid/
drwxr-xr-x  3.0 unx        0 bx stor 25-Apr-01 10:51 astroid/ | drwxr-xr-x  3.0 unx        0 bx stor 25-Apr-01 10:52 astroid/
-rw-r--r--  3.0 unx     2515 tx defN 25-Apr-01 10:51 astroid/ | -rw-r--r--  3.0 unx     2515 tx defN 25-Apr-01 10:52 astroid/
drwxr-xr-x  3.0 unx        0 bx stor 25-Apr-01 10:51 astroid/ | drwxr-xr-x  3.0 unx        0 bx stor 25-Apr-01 10:52 astroid/
...
```

Okay, now we can see that some of the files within the archives themselves have different timestamps. Let's set the timestamp of each file in our build directory before we zip it all up. Our `makefile` now looks like this-

```
%.zip: .venv
	mkdir -p $*.pkg
	cp -r .venv/lib/python3.12/site-packages/** $*.pkg
	cp -r src/** $*.pkg
	find $*.pkg -exec touch -t $$(git log -1 --date=format:"%Y%m%d%H%M" --format="%ad" -- src) {} + 2>/dev/null
	cd $*.pkg && zip -r -q $*.zip .
	mv $*.pkg/$*.zip $*.zip
	touch -t $$(git log -1 --date=format:"%Y%m%d%H%M" --format="%ad" -- src) $*.zip
```

```
 diff -s <(zipinfo alpha.zip) <(zipinfo bravo.zip)
1c1
< Archive:  alpha.zip
---
> Archive:  bravo.zip
 md5sum alpha.zip
b84f9f7444cbdc77c5c5a59a9348ae96  alpha.zip
 md5sum bravo.zip
abe69995e19161e8d6be87d149aeaeda  bravo.zip
```

That's looking better, but not perfect. The only difference we can see between the archives is the name (which doesn't affect the hash, remember, that's just an artifact of the `diff` tool) but the hashes of the archives are still different. Let's start seeing which files within the archives are different by comparing hashes of individual files.

```
 find . -type f -exec md5sum {} \; > ../alpha.txt
...
 find . -type f -exec md5sum {} \; > ../bravo.txt
...
 diff -y --suppress-common-lines --width 250 alpha.txt bravo.txt
208b8192629825bf32307d858b4e8fb6  ./__pycache__/_virtualenv.cpython-312.pyc						    |	8689aa583f44a5d671be83c1aa48447a  ./__pycache__/_virtualenv.cpython-312.pyc
```

There's the offending file- a .pyc file. A quick google for 'pyc file' says it's fine to remove this for some reason. These .pyc files are a fact of life for Python developers, don't worry about them, they aren't super important. Your deployed application will work just fine without them.

Okay, that sounds like it makes our lives easier! Let's quickly verify that removing this .pyc from the build package causes our package hashes to match- `cd $*.pkg && find . -name *.pyc -exec rm {} \;`. 

```
 md5sum alpha.zip
7612c513f7df779bc6aff1a1a63dba3c  alpha.zip
 md5sum bravo.zip
7612c513f7df779bc6aff1a1a63dba3c  bravo.zip
```

Huzzah! We have matching hashes, and therefore our Terraform Plan should stop saying that there are changes to deploy to our Lambda when there aren't, in fact, any changes. Job done, right?

Maybe.

A .pyc file is a binary file that the Python interpreter produces when a .py file is first loaded for execution. Contrary to popular belief, Python does actually need to be compiled when it's being run. However in contrast to a language like C the compilation is done on the fly, as needed during program execution. You can observe this yourself by starting a Python repl and importing a source file in the repl. You'll see a __pycache__ directory created after you do this and it will contain all the pyc files for the Python module you just imported for execution. The interpreter only needs to do this once for each source file you execute. Next time that source file is used it uses the existing pyc file. 

On the one hand, if the Python interpreter is capable of creating its own pyc files then we can just remove them from the build package and let the Lambda run time create them on the fly. But on the other hand, there must be some overhead in creating those pyc files for the first time. That naturally leads us to a few questions-

- Can we compile pyc files ahead of time (during our build process)?
- In our example from the previous section, why were the created pyc files different for each build?
- By pre-compiling, can we measure any kind of impact on execution time of our code?

The first question is easily answered-
```
python -m compileall src/log.py
```
And we end up with a file like so-
```
 ls src/__pycache__/log.cpython-312.pyc
src/__pycache__/log.cpython-312.pyc
```

This [PEP](https://peps.python.org/pep-0552) has some interesting details about how pyc files are constructed. The germane part of this is the fact that the bytes of a pyc file are affected by the modification timestamp of the source .py file. So if you `touch` a py file, run the `compileall` command, `touch` it again, and `compileall` again, you'll end up with two different pyc files, even if the source file is no different. It's not clear to me why this is the case, but I can imagine it being useful when determining whether a pyc file needs to be re-created possibly. 

So if we assume that there are some benefits to having pyc files pre-compiled in our Lambda source package (more on this anon) then we could possibly make sure our zip archives have the same hash each time by touching the source files in our build directory, compiling, and then touching all the pyc files with the same timestamp. So our makefile would look something like this-

```
%.zip: .venv
	mkdir -p $*.pkg
	cp -r .venv/lib/python$(python_version)/site-packages/** $*.pkg                                                 # Put our dependencies in the build directory
	cp -r src/** $*.pkg                                                                                             # Put our source files in the build directory
	find $*.pkg -exec touch -t $$(git log -1 --date=format:"%Y%m%d%H%M" --format="%ad" -- src) {} + 2>/dev/null     # Set the last modified timestamp to the timestamp of the last git commit so the compiled pyc files are consistently generated
	poetry run python -m compileall -f -s $*.pkg -q $*.pkg                                                          # Pre-compile the .py files into .pyc files
	find $*.pkg -exec touch -t $$(git log -1 --date=format:"%Y%m%d%H%M" --format="%ad" -- src) {} + 2>/dev/null     # Now set the modified timestamp of the new .pyc files consistently, to match the .py files
	cd $*.pkg && zip -r -q $*.zip .
	mv $*.pkg/$*.zip $*.zip
	touch -t $$(git log -1 --date=format:"%Y%m%d%H%M" --format="%ad" -- src) $*.zip
```

And lo- 

```
 md5sum alpha.zip bravo.zip
0f1d2797b829b9ec141b9e66e9b24913  alpha.zip
0f1d2797b829b9ec141b9e66e9b24913  bravo.zip
```

So how much of an impact does precompiling the pyc files actually have? To be clear, pyc files only need to be compiled to bytecode the first time your application loads the code for execution, so any performance boost is a one-time deal. An hour searching Google for data on cold start times where the interpreter needs to compile .pyc files doesn't turn up any hard data. The variance between Python projects, in terms of number of dependencies pulled in, and the number of lines of Python, likely makes it hard to measure with any rigour. A simple way to measure however, could be to time the `compileall` command during the build by prefixing it with `time`.

```
time poetry run python -m compileall -f -s alpha.pkg -q alpha.pkg

real	0m8.109s
user	0m3.777s
sys	    0m1.494s
```

The above output is fairly representative of me running the build process a dozen times. Hardly scientific, but compelling enough to make me think that a modestly sized project deployed as a cold-starting lambda, that has to compile every dependency on cold start, would lead to a fairly appalling user experience if someone were unlucky enough to be the first person to invoke your lambda. After the hard work of figuring out how to generate deterministic zip archives, and having done the research into what exactly .pyc files are, I find it hard to argue against this sort of pre-compilation.
