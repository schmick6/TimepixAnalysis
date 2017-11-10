# this script is used to extract the number of scintillator triggers in a given
# event set

import os
#import ingrid/tos_helper_functions
import tables
import re
import helper_functions
import strutils

proc readEventHeader*(filepath: string): Table[string, string] =
  # this procedure reads a whole event header and returns 
  # a table containing the data, where the key is the key from the data file
  result = initTable[string, string]()
  
  # we define a regex for the header of the file
  let regex = r"^\#\# (.*):\s(.*)"
  var matches: array[2, string]
  for line in lines filepath:
    if line.match(re(regex), matches):
      # get rid of whitespace and add to result
      let key = strip(matches[0])
      let val = strip(matches[1])
      result[key] = val

proc main() =
  let args_count = paramCount()
  if args_count < 1:
    echo "Please hand a run folder"
    quit()

  let input_folder = paramStr(1)

  var scint1_hits = initTable[string, int]()
  var scint2_hits = initTable[string, int]()

  # first check whether the input really is a valid folder
  if existsDir(input_folder) == true:
    # get the list of files in the folder
    let files = getListOfFiles(input_folder, r"^.*data\d\d\d\d\d\d\.txt$")
    var inode_tab = createInodeTable(files)
    sortInodeTable(inode_tab)
    
    var count = 0
    for tup in pairs(inode_tab):
      let file = tup[1]

      let t = readEventHeader(file)
      let scint1 = parseInt(t["szint1ClockInt"])
      let scint2 = parseInt(t["szint2ClockInt"])
      let fadc_triggered = if parseInt(t["fadcReadout"]) == 1: true else: false
      # make sure we only read the scintillator counters, in case the fadc was 
      # actually read out. Otherwise it does not make sense (scintis not read out)
      # and the src/waitconditions bug causes overcounting
      if fadc_triggered:
        if scint1 != 0:
          scint1_hits[file] = scint1
        if scint2 != 0:
          scint2_hits[file] = scint2
      if count mod 500 == 0:
        echo count, " files read. Scint counters: 1 = ", len(scint1_hits), "; 2 = ", len(scint2_hits)
      count = count + 1
  else:
    echo "Input folder does not exist. Exiting..."
    quit()

  # all done, print some output
  echo "Reading of all files in folder ", input_folder, " finished."
  echo "\t Scint1     = ", len(scint1_hits)
  echo "\t Scint2     = ", len(scint2_hits)

  proc min_of_table(tab: Table[string, int]): tuple[min_val: int, file_min: string] =
    var min_val = 9999
    var file_min = ""
    for pair in pairs(tab):
      let val = pair[1]
      if val < min_val:
        min_val = val
        file_min = pair[0]
    result = (min_val, file_min)
  
  let min_tup1 = min_of_table(scint1_hits)
  let min_tup2 = min_of_table(scint2_hits)

  echo "\t Scint1_min = ", min_tup1[0], " in file ", min_tup1[1]
  echo "\t Scint2_min = ", min_tup2[0], " in file ", min_tup2[1]
    

when isMainModule:
  main()
