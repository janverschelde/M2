--		Copyright 1995-2002 by Daniel R. Grayson

-- This version of 'run' doesn't handle pipes or redirection, of course
-- but it's an advantage to have this facility without depending on an outside shell.
-- We comment it out because some systems don't have wordexp() in libc, upon which 
-- expandWord is based.
-- run = cmd -> if (pid := fork()) == 0 then exec expandWord cmd else wait pid

setUpApplicationDirectory = () -> (
     dir := applicationDirectory();
     makeDirectory(dir);
     makeDirectory(dir|"encap/");
     makeDirectory(dir|"local/");
     makeDirectory(dir|"code/");
     f := (n,c) -> (n = dir|n; if not fileExists n then n << c << close);
     f("init.m2", sampleInitFile);
     f("README", readmeFile);
     )

topFileName = "index.html"				    -- top node's file name, constant

restart = Command ( 
     () -> (
	  restarting = true;
	  runEndFunctions();
	  scan(openFiles(), f -> if f =!= stdio and f =!= stderr then close f);
	  exec if member("--restarted",commandLine) then commandLine else join({commandLine#0,"--restarted"},drop(commandLine,1))
	  )
     )

setRandomSeed = method()
installMethod(setRandomSeed, () -> rawRandomInitialize())
setRandomSeed ZZ := seed -> randomSeed = seed		    -- magic assignment, calls rawSetRandomSeed internally
setRandomSeed String := seed -> setRandomSeed fold((i,j) -> 101*i + j, 0, ascii seed)

currentLayoutTable := new MutableHashTable

addLayout = (prefix,i) -> (
     assert (i === 1 or i === 2);
     assert not currentLayoutTable#?prefix;
     currentLayoutTable#prefix = i;
     if notify or debugLevel == 11 then stderr << "--Layout#" << i << " assigned for directory " << prefix << endl;
     i)

layoutToIndex := layout -> if layout === Layout#1 then 1 else if layout === Layout#2 then 2 else error "nonstandard layout detected"

addLayout(prefixDirectory, layoutToIndex currentLayout)	   -- detected in startup.m2.in
							      -- it's layout 1 when running from an installed M2, almost certainly
							      -- it's layout 2 when running from a Macaulay2 build directory while compiling from source code

addLayout(applicationDirectory()|"local/", 1) -- the user's application directory always uses layout 1

detectCurrentLayout = prefix -> (
     -- If at least one package is installed under the prefix directory, we can detect the layout.
     -- If none are installed, then it doesn't matter and we return null.
     -- In the future we may dispense with layout # 2 and have just one layout, but for now, we put up with the bureaucracy.
     if currentLayoutTable#?prefix 
     then currentLayoutTable#prefix
     else if isDirectory (prefix | Layout#1#"packages") and isDirectory (prefix | replace("PKG",".",Layout#1#"packagelib"))
     then addLayout(prefix,1)
     else if isDirectory (prefix | Layout#2#"packages") and isDirectory (prefix | replace("PKG",".",Layout#2#"packagelib"))
     then addLayout(prefix,2)
     else null)

searchPrefixPath = f -> (
     -- I'm not sure we should retain this function.
     assert instance (f, Function);
     -- Here f is a function from layout tables to file paths, so we make no assumption about how the paths in one layout table differ from those in the other.
     -- We search the prefixPath for an entry where the appropriate file path leads to an existing file.
     -- The idea is that the documentation of a package may result in links to the html documentation pages of any package installed already on the prefixPath.
     fl := (,f Layout#1,f Layout#2);
     found := for pre in prefixPath do (
	  i := detectCurrentLayout pre;
	  if i === null then continue;
	  if fileExists (pre|fl#i) then break pre|fl#i;
	  );
     if found =!= null then (
	  if debugLevel > 5 then stderr << "--file found in " << found << endl;
	  found)
     else (
     	  if debugLevel > 5 then stderr << "--file not found in prefixPath = " << stack prefixPath << endl;
	  ))

getDBkeys = dbfn -> (
     dbkeys := new MutableHashTable;
     db := openDatabase dbfn;
     for key in keys db do dbkeys#key = 1;
     close db;
     dbkeys)

makePackageInfo := (pkgname,prefix,dbfn,layoutIndex) -> (
     new MutableHashTable from {
	  "doc db file name" => dbfn,
	  "doc db file time" => fileTime dbfn, -- if this package is reinstalled, we can tell by checking this time stamp (unless the package takes less than a second to install, which is unlikely)
	  -- "doc keys" => getDBkeys dbfn, -- do this lazily, getting it later, when needed for "about"
	  "prefix" => prefix,
     	  "layout index" => layoutIndex,
	  "name" => pkgname
	  })

fetchDocKeys = i -> (
     if i#?"doc keys"
     then i#"doc keys"
     else i#"doc keys" = getDBkeys i#"doc db file name"
     )

installedPackagesByPrefix = new MutableHashTable

allPackages = () -> unique sort flatten for prefix in keys installedPackagesByPrefix list keys installedPackagesByPrefix#prefix#"package table"

getPackageInfo = pkgname ->				    -- returns null if the package is not installed
     for prefix in prefixPath 
     do if installedPackagesByPrefix#?prefix 
        then if installedPackagesByPrefix#prefix#"package table"#?pkgname 
	     then return installedPackagesByPrefix#prefix#"package table"#pkgname

locatePackageFile = (defaultPrefix,defaultLayoutIndex,pkgname,f) -> (
     -- Here f is a function from layout tables to file paths
     -- Maybe it would also make sense for f to accept two arguments, the layout table and package name.
     -- We don't test for file existence, because the package may not be installed yet: consider that case where two
     -- packages have links to each other's documentation nodes.
     -- Assuming that the uninstalled package will be installed under the defaultPrefix causes some uncertainty
     i := getPackageInfo pkgname;
     prefix := if i === null then defaultPrefix else i#"prefix";
     layoutIndex := detectCurrentLayout prefix;
     if layoutIndex === null then layoutIndex = defaultLayoutIndex;
     tail := f Layout#layoutIndex;
     assert isAbsolutePath prefix;
     if not fileExists (prefix|tail) 
     then stderr << "--warning: file " << baseFilename tail << " not installed yet in package " << pkgname << endl; -- we may want to hush these warnings
     (prefix, tail)                 -- we return a pair so a relative link to the file can be created if the two prefixes are the same
     )

locatePackageFileRelative = (defaultPrefix,defaultLayoutIndex,pkgname,f,installPrefix,installTail) -> (
     (prefix,tail) := locatePackageFile(defaultPrefix,defaultLayoutIndex,pkgname,f);
     if prefix === installPrefix			    -- we assume these are both real paths, without symbolic links
     then relativizeFilename(installTail,tail)
     else prefix|tail)

locateCorePackageFile = (pkgname,f) -> locatePackageFile(prefixDirectory,currentLayout,pkgname,f)

locateCorePackageFileRelative = (pkgname,f,installPrefix,installTail) -> locatePackageFileRelative(prefixDirectory,currentLayout,pkgname,f,installPrefix,installTail)

locateDocumentationNode = method()

keyExists = (i,fkey) -> (
     if i#?"doc keys" 
     then i#"doc keys"#?fkey
     else (
	  db := openDatabase i#"doc db file name";	    -- how long does it take to open and close 170 database files?
	  r := db#?fkey;
	  close db;
	  r))

locateDocumentationNode (String,String) := (pkgname,fkey) -> (
     i := getPackageInfo pkgname;
     if i === null or not keyExists(i,fkey) then return null;
     layout := Layout#(i#"layout index");
     fn := i#"prefix" | htmlFilename1(fkey,pkgname,layout);
     if not fileExists fn then error ("internal error: html documentation file does not exist: ",fn);
     fn)

locateDocumentationNode String := fkey -> (			    -- search packages for one with a documentation node under this formatted key, unless it contains "::"
     r := regex(" *:: *",fkey);
     if r === null then (
	  for prefix in prefixPath
	  do if installedPackagesByPrefix#?prefix
	  then (
	       pkgtable := installedPackagesByPrefix#prefix#"package table";
	       for pkgname in keys pkgtable do (
		    q := pkgtable#pkgname;
		    if keyExists(q,fkey) then (
			 layout := Layout#(q#"layout index");
			 fn := prefix | htmlFilename1(fkey,pkgname,layout);
			 if not fileExists fn then error ("internal error: html documentation file does not exist: ",fn);
			 return fn))))
     else (
	  (off,len) := r#0;
	  pkgname := substring(0,off,fkey);
	  fkey = substring(off+len,fkey);
	  locateDocumentationNode(pkgname,fkey)))

getPackageInfoList = () -> flatten (
     for prefix in prefixPath 
     list if installedPackagesByPrefix#?prefix
          then for pkgname in keys installedPackagesByPrefix#prefix#"package table"
	       list installedPackagesByPrefix#prefix#"package table"#pkgname
	  else {})

tallyInstalledPackages = () -> for prefix in prefixPath do (
     if not isDirectory prefix then (
	  remove(installedPackagesByPrefix,prefix);
	  continue;
	  );
     currentLayoutIndex := detectCurrentLayout prefix;
     if currentLayoutIndex === null then (
	  remove(installedPackagesByPrefix,prefix);
	  continue;
	  );
     layout := Layout#currentLayoutIndex;
     docdir := prefix | layout#"docdir";
     if not isDirectory docdir then (
	  remove(installedPackagesByPrefix,prefix);
	  continue;
	  );
     -- note: we assume that the packagedoc directory is obtained from the docdir directory by appending the name of the package, as here in Layout#1
     --   docdir => share/doc/Macaulay2/
     --   packagedoc => share/doc/Macaulay2/PKG/
     -- or as here in Layout#2:
     --   docdir => common/share/doc/Macaulay2/
     --   packagedoc => common/share/doc/Macaulay2/PKG/
     docdirtime := fileTime docdir;
     if not (installedPackagesByPrefix#?prefix and installedPackagesByPrefix#prefix#"docdir time stamp" === docdirtime)
     then (
	  -- packages have been added or removed, so do a complete scan
	  installedPackagesByPrefix#prefix = new HashTable from {
	       "docdir time stamp" => docdirtime,
	       "package table" => p := new MutableHashTable};
	  for pkgname in readDirectory docdir do if pkgname =!= "." and pkgname =!= ".." and isDirectory (docdir | pkgname) then (
	       dbfn := databaseFilename (layout,prefix,pkgname);
	       if not fileExists dbfn then continue;	    -- maybe installation was interrupted, so ignore this package
	       p#pkgname = makePackageInfo(pkgname,prefix,dbfn,currentLayoutIndex);))
     else (
	  -- no packages have been added or removed, so scan the packages previously encountered
	  -- well, sometimes it takes less than a second to uninstall a package, so be careful about that case
	  p = installedPackagesByPrefix#prefix#"package table";
	  for pkgname in keys p do (
	       q := p#pkgname;
	       dbfn := q#"doc db file name";
	       if not (isDirectory (docdir | pkgname) and fileExists dbfn) then (
		    -- it must have been removed in less than a second; this can happen if you remove two packages, because it rescans each time
		    remove(p,pkgname);
		    continue;
		    );
	       if q#"doc db file time" === fileTime dbfn then continue; -- not changed
	       p#pkgname = makePackageInfo(pkgname,prefix,dbfn,currentLayoutIndex);)))     

-- Local Variables:
-- compile-command: "make -C $M2BUILDDIR/Macaulay2/m2 "
-- End:
