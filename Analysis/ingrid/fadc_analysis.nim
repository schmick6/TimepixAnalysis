# this file contains procs, which deal with the analysis of the
# FADC data stored in a H5 file

import strutils, sequtils, strformat
import docopt
import ospaths
import nimhdf5
import tables
import times
import future
import typetraits

import arraymancer
import seqmath

import tos_helpers
import helpers/utils

let doc = """
InGrid FADC analysis tool

Usage:
  fadc_analysis <HDF5file> [options]
  fadc_analysis <HDF5file> --run_number <number> [options]
  fadc_analysis <HDF5file> --noise_analysis <outfile> [options]
  fadc_analysis -h | --help
  fadc_analysis --version

Options:
  --run_number <number>       Only work on this run (currently only supported)
  --noise_analysis <outfile>  If set only perform analysis of FADC noise
  -h --help                   Show this help
  --version                   Show version.
"""

# proc noiseAnalysis(h5f: var H5FileObj) =
#   ## proc which performs the analysis of the noise, i.e. ratio of active and dead
#   ## detector. Read the timestamps in the files, get event durations and in bin
#   ## ranges, which can be determined (~ 20 s to account for 1s accuracy in timestamp?)

#   const avg_int = 10
#   for num, group in runs(h5f):
#     echo num, " and ", group
#     # so what do we need to do? Get timestamps.
#     # get each event, check if noisy (use noisy flag)
#     # define bin by starting at t = t0, build up some
#     # seq of noisy, not noisy
#     # once t = t1, where delta t = t1 - t0
#     # we calculate ratio of noisy vs non noisy
#     # given shift start and end times, we can later extract
#     # noise development
#     let tstamp = h5f[(group / "timestamp").dset_str][int64]
#     let noisy  = h5f[(group / "fadc/noisy").dset_str][int64]
#     var
#       n_noise = 0
#       n_good  = 0
#       t_0     = tstamp[0]
#       noise_frac: seq[float] = @[]
#     # TODO: good start, but still wrong. Less FADC events than timestamps
#     # thus also need fadc_readout dataset to get the times of each FADC
#     # event. That is to know when each happened etc
#     # then also need not only fraction of noisy events, but also effective
#     # dead time. So we need also eventDuration

#     for i, t in tstamp:
#       if tstamp[i] - t_0 > avg_int:
#         noise_frac.add (n_noise / n_good)
#         n_noise = 0
#         n_good = 0
#         t_0 = tstamp[i]
#       else:
#         if noisy[i] == 1:
#           inc n_noise
#         else:
#           inc n_good
#     echo "Noise fracs are ", noise_frac
#     quit()

type
  FadcIntTime = enum
    fk50, fk100

proc getFadcIntTime(date: DateTime): FadcIntTime =
  ## given a `date` we return whether this corresponds to
  ## 50 ns or 100 ns FADC integration time
  # 29/11/17 change diff and amp
  # <2017-12-07 Thu 8:00>  int 50 ns -> 100 ns
  # <2017-12-08 Fri 17:50> int 100 ns -> 50 ns
  # <2017-12-15 Fri 10:20> int 50 ns -> 100 ns
  let
    t1 = initDateTime(7, mDec, 2017, 8, 0, 0)
    t2 = initDateTime(8, mDec, 2017, 17, 50, 0)
    t3 = initDateTime(15, mDec, 2017, 10, 20, 0)
  if date < t1:
    result = fk50
  elif date > t1 and date < t2:
    result = fk100
  elif date > t2 and date < t3:
    result = fk50
  elif date > t3:
    result = fk100

proc noiseAnalysis(h5f: var H5FileObj): tuple[f50, f100: Table[string, float64]] =
  ## proc which performs the analysis of the noise, i.e. ratio of active and dead
  ## detector. Read the timestamps in the files, gets start and end times of runs
  ## and compares total dead time for each run, depending on type of FADC setting
  ## NOTE: simpler approach to the problem compared to the (commented out )
  ## version above
  const date_syntax = getDateSyntax()

  # table to store (middle) dates of each run and the corresponding percentage
  # the detector was active. For 50 and 100 ns integration time
  var date_tab_50  = initTable[string, float64]()
  var date_tab_100 = initTable[string, float64]()

  for num, group in runs(h5f):
    # for each event we get the start and end time of the tracking
    # calculate the time difference between start and end (to get total
    # time) and sum up the time the detector was active using
    # eventDuration
    let grp = h5f[group.grp_str]
    var attrs = grp.attrs
    echo "Group is ", grp.name
    if "num_trackings" notin attrs:
      # if no tracking at all, skip this run
      continue
    let ntrackings = attrs["num_trackings", int]
    for i in 0 ..< ntrackings:
      let
        tr_start = attrs[&"tracking_start_{i}", string].parse(date_syntax)
        tr_stop  = attrs[&"tracking_stop_{i}", string].parse(date_syntax)
        tr_mean  = tr_start + initDuration(
          seconds = ((tr_stop - tr_start).seconds.float / 2).round.int
        )
      let
        durations = h5f[(group / "eventDuration").dset_str][float64]
        # get tracking indices of this tracking number
        tracking_inds = h5f.getTrackingEvents(grp, i, tracking = true)
        # get all durations for events within tracking from the tstamp indices
        durations_track = durations[tracking_inds]
        # sum all event durations within tracking
        duration_live = initDuration(seconds = durations_track.sum.int)
      let
        # calculate shutter open time
        ratio = duration_live.seconds.float / (tr_stop - tr_start).seconds.float
        fk_type = getFadcIntTime(tr_mean)
      # build the key for the table consisting of run number, FADC int time
      # and the date
      let key = &"{fk_type} \t {num} \t {$tr_mean}"
      # add to output tables, depending on which type it is
      case fk_type
      of fk50:
        date_tab_50[key] = ratio
      of fk100:
        date_tab_100[key] = ratio

      when not defined(release):
        # debugging..
        echo "Number of trackings ", ntrackings
        echo "Start ", tr_start
        echo "Stop  ", tr_stop
        echo "Middle time ", tr_mean
        echo "Tracking corresponds to ", getFadcIntTime(tr_mean)
        echo "Length of run ", tr_stop - tr_start
        echo "Total live time ", duration_live
        echo "Ratio is ", ratio

  if date_tab_50.len > 0:
    echo "Fk50 mean ratio ", toSeq(values(date_tab_50)).mean
  if date_tab_100.len > 0:
    echo "Fk100 mean ratio ", toSeq(values(date_tab_100)).mean
  result.f50 = date_tab_50
  result.f100 = date_tab_100

proc writeNoiseData(tab_tup: tuple[f50, f100: Table[string, float64]], outfile: string) =
  ## proc to write the ratio of noisy data from for both FADC integration
  ## times into a file
  let
    t50 = tab_tup.f50
    t100 = tab_tup.f100
  var outf = open(outfile, fmWrite)
  outf.write("# 50 ns integration time\n")
  outf.write("# fadcIntTime \t run_number \t run_date \t live_ratio\n")
  for k, v in t50:
    outf.write(&"{k} \t {v}\n")
  outf.write("# 100 ns integration time\n")
  for k, v in t100:
    outf.write(&"{k} \t {v}\n")


proc findThresholdValue[T](data: seq[seq[T]], x_min: seq[int], threshold: seq[T], left = true, positive = false): seq[int] =
  ## left determines whether we start search left or right
  ## positive sets the range of the data. postiive == false means we consider
  ## dips instaed of peaks
  result = newSeq[int](x_min.len)
  for i, el in data:
    let thr     = threshold[i]
    var x = x_min[i]
    var count = 0
    while el[x] < thr and count < 2560:
      # positive == true would mean el[x] > thr
      if left == true:
        dec x
        if x <= 0:
          x = el.high
      else:
        inc x
        if x >= el.high:
          x = 0
      inc count
    # once we're out, we found our threshold in the data
    if count >= 2560:
      # set the threshold value to the start value, indicating, that
      # it could not be found
      result[i] = x_min[i]
    else:
      # in case of a good result..
      result[i] = x

proc diffUnderModulo[T](a, b: T, modulo: int): T {.inline.} =
  ## returns the difference between two values taking into account
  ## modulo a certain value
  let
    d1 = abs(a - b)
    d2 = abs(modulo - abs(a - b))
  result = min(d1, d2)

proc calcRiseAndFallTimes*(h5f: var H5FileObj, run_number: int) =
  ## proc which reads the FADC data from the given file
  ## then performs the calculation of fall and rise time
  ## starting from the index of the minimum

  let
    fadc_group = fadcDataBasename(run_number)
  var
    fadc = h5f[fadc_group.dset_str]

  let t0 = epochTime()
  let fadcShape = fadc.shape
  let nEvents = fadcShape[0]
  var f_data = fadc[float64].reshape2D(fadcShape)

  # given the reshaped array, we can now compute the
  # fall and rise times

  # get location of minimum
  let x_min = mapIt(f_data, argmin(it.toTensor))

  let t1 = epochTime()
  echo "Getting all minima took $# seconds" % $(t1 - t0)

  # now determine baseline + 10 % of its maximum value
  let baseline = mapIt(f_data, it.percentile(p = 50) + system.max(it) * 0.1)
  let t2 = epochTime()
  echo "Baseline calc took $# seconds" % $(t2 - t1)

  # now determine rise and fall times
  let
    rise_start = findThresholdValue(f_data, x_min, baseline)
    fall_stop = findThresholdValue(f_data, x_min, baseline, left = false)

  # given this data, we could now in principle already calculate the fall and rise
  # times in nano seconds, but we're going to stick to registers for now
  let
    rise_times = mapIt(zip(x_min, rise_start), diffUnderModulo(it[0], it[1], 2560))
    fall_times = mapIt(zip(x_min, fall_stop), diffUnderModulo(it[1], it[0], 2560))

  # now write data back to h5file
  var
    base_dset = h5f.create_dataset(fadcBaselineBasename(run_number), nEvents, float)
    x_min_dset = h5f.create_dataset(argMinvalBasename(run_number), nEvents, uint16)
    rise_s_dset = h5f.create_dataset(riseStartBasename(run_number), nEvents, uint16)
    fall_s_dset = h5f.create_dataset(fallStopBasename(run_number), nEvents, uint16)
    rise_t_dset = h5f.create_dataset(riseTimeBasename(run_number), nEvents, uint16)
    fall_t_dset = h5f.create_dataset(fallTimeBasename(run_number), nEvents, uint16)

  # convert data to uint16
  let
    x_min_u = x_min.asType(uint16)
    rise_start_u = rise_start.asType(uint16)
    fall_stop_u = fall_stop.asType(uint16)
    rise_times_u = rise_times.asType(uint16)
    fall_times_u = fall_times.asType(uint16)

  # write the data
  let all = base_dset.all
  base_dset[all] = baseline
  x_min_dset[all] = x_min_u
  rise_s_dset[all] = rise_start_u
  fall_s_dset[all] = fall_stop_u
  rise_t_dset[all] = rise_times_u
  fall_t_dset[all] = fall_times_u

proc main() =
  let args = docopt(doc)
  echo args

  let
    h5file = $args["<HDF5file>"]
    run_number = $args["--run_number"]


  var h5f = H5File(h5file, "rw")
  if run_number != "nil":
    calcRiseAndFallTimes(h5f, parseInt(run_number))
  elif $args["--noise_analysis"] != "nil":
    let outfile = $args["--noise_analysis"]
    let t_tup = noiseAnalysis(h5f)
    writeNoiseData(t_tup, outfile)
  echo "H5 library closed with ", h5f.close()

when isMainModule:
  main()
