import nimhdf5, seqmath, sequtils
import tables
import times
import strformat, strutils, ospaths
import arraymancer

import databaseDefinitions, databaseUtils

# cannot import `Chip`, due to clash with this modules `Chip`
import ingrid/ingrid_types except Chip
import helpers/utils
import zero_functional

proc writeTotCalibAttrs*(h5f: var H5FileObj, chip: string, fitRes: FitResult) =
  ## writes the fit results as attributes to the H5 file for `chip`
  # group object to write attributes to
  var mgrp = h5f[chip.grp_str]
  # map parameter names to their position in FitResult parameter seq
  const parMap = { "a" : 0,
                   "b" : 1,
                   "c" : 2,
                   "t" : 3 }.toTable
  mgrp.attrs["TOT Calibration"] = "performed at " & $now()
  for key, val in parMap:
    mgrp.attrs[key] = fitRes.pRes[val]
    mgrp.attrs[&"{key}_err"] = fitRes.pErr[val]

proc writeThreshold*(h5f: var H5FileObj, threshold: Threshold, chipGroupName: string) =
  var thresholdDset = h5f.create_dataset(joinPath(chipGroupName, ThresholdPrefix),
                                          (256, 256),
                                          dtype = int)
  thresholdDset[thresholdDset.all] = threshold.data.reshape([256, 256])

proc writeCalibVsGasGain*(gain, calib, calibErr: seq[float64],
                          fitResult: FitResult,
                          chipName: string) =
  ## writes the fit data and results of the Fe charge spectrum vs gas gain
  ## fit to the database.
  var db = H5File(dbPath, "rw")
  defer: discard db.close()
  let grpName = chipNameToGroup(chipName)
  var mgrp = db[grpName.grp_str]
  # create new dataset
  var mdset = db.create_dataset(grpName / ChargeCalibGasGain,
                                 (gain.len, 3),
                                 dtype = float64)
  let data = zip(gain, calib, calibErr) -->> map(@[it[0], it[1], it[2]]) --> to(seq[seq[float]])
  # store data as (N, 3) dataset.
  mdset[mdset.all] = data
  # write fit parameters as attributes
  mdset.attrs["Units of fit parameters"] = "1e-6 keV / e-"
  mdset.attrs["Fit func"] = "y = m * x + b"
  mdset.attrs["m"] = fitResult.pRes[1]
  mdset.attrs["b"] = fitResult.pRes[0]
  mdset.attrs["mErr"] = fitResult.pErr[1]
  mdset.attrs["bErr"] = fitResult.pErr[0]
  mdset.attrs["Chi^2 / dof"] = fitResult.redChiSq


proc addChipToH5*(chip: Chip,
                  fsr: FSR,
                  scurves: SCurveSeq,
                  tot: Tot,
                  threshold: Threshold,
                  thresholdMeans: ThresholdMeans) =
  ## adds the given chip to the InGrid database H5 file

  var h5f = H5File(dbPath, "rw")
  var chipGroup = h5f.create_group($chip.name)
  # add FSR, chipInfo to chipGroup attributes
  for key, value in chip.info:
    echo &"Appending {key} with {value}"
    chipGroup.attrs[key] = if value.len > 0: value else: "nil"
  for dac, value in fsr:
    chipGroup.attrs[dac] = value

  # SCurve groups
  if scurves.files.len > 0:
    var scurveGroup = h5f.create_group(joinPath(chipGroup.name, SCurveFolder))
    for i, f in scurves.files:
      # for each file write a dataset
      let curve = scurves.curves[i]
      # get the actual filename from the curve (potentially contains full path)
      let (_, curveName, _) = curve.name.splitFile
      var scurveDset = h5f.create_dataset(joinPath(scurveGroup.name,
                                                   curveName),
                                          (curve.thl.len, 2),
                                          dtype = float)
      # reshape the data to be two columns of [thl, hits] pairs and write
      scurveDset[scurveDset.all] = zip(curve.thl.asType(float), curve.hits).mapIt(@[it[0], it[1]])
      # add voltage of dataset as attribute (for easier reading)
      scurveDset.attrs["voltage"] = curve.voltage

  if tot.pulses.len > 0:
    # TODO: replace the TOT write by a compound data type using TotType
    # that allows us to easily name the columns too!
    echo sizeof(TotType)
    var totDset = h5f.create_dataset(joinPath(chipGroup.name, TotPrefix),
                                     (tot.pulses.len, 3),
                                     dtype = float)
    # sort of ugly conversion to 3 columns, using double zip
    # since we don't have a zip for more than 2 seqs
    totDset[totDset.all] = zip(zip(tot.pulses.asType(float),
                               tot.mean),
                               tot.std).mapIt(@[it[0][0],
                                                it[0][1],
                                                it[1]])

  if threshold.shape == @[256, 256]:
    h5f.writeThreshold(threshold, chipGroup.name)

  #if thresholdMeans.shape == @[256, 256]:
  #  h5f.writeThreshold(thresholdMeans, chipGroup.name)

  let err = h5f.close()
