
import std/[parsecfg, strutils, nativesockets, logging, os]
import pkg/[serverloggers]


type
  LoggingFacility* = enum
    LF_CONSOLE
    LF_FILE
    LF_RSYSLOG

  StatsDConfig* = object
    addressHost*: string
    addressPort*: Port
    deleteGauges*: bool
    flushInterval*: int
    graphiteHost*: string
    graphitePort*: Port
    postfix*: string
    prefix*: string
    tcpHost*: string
    tcpPort*: Port
    tcpEna*: bool
    persistCountKeys*: int
    percentiles*: seq[Percentile]
    logLevel*: logging.Level
    logFacility*: LoggingFacility
    fileName*: string
    fileMaxRotations*: int
    fileRotationType*: FileLoggerRotations
    rsysLogURL*: string
    logFormat*: string
    logName*: string
    debug*: bool
  
  Percentile* = object
    flt*: float64
    str*: string


proc initConfig(
  address: string = "0.0.0.0:8125", 
  deleteGauges: bool = true,
  flushInterval: int = 10,
  graphite: string = "127.0.0.1:2003",
  prefix: string = "", 
  postfix: string = "", 
  tcpAddr: string = "",
  persistCountKeys: int = 60,
  percentiles: seq[string] = @[],
  logLevel: string = "",
  logTo: string = "",
  fileName: string = "",
  fileMaxRotations: int = 1,
  fileRotationType: string = "",
  rsysLogURL: string = "",
  logFormat: string = "",
  logName: string = "",
  debug: bool = false
  ): StatsDConfig =
  var splits = address.rsplit(':', maxSplit=1)
  if splits.len == 1:
    result.addressHost = splits[0]
    result.addressPort = Port(8125)
  else:
    result.addressHost = splits[0]
    result.addressPort = Port(parseBiggestInt(splits[1]))
  result.deleteGauges = deleteGauges
  result.flushInterval = flushInterval*1000
  splits = graphite.rsplit(':', maxSplit=1)
  if splits.len == 1:
    result.graphiteHost = splits[0]
    result.graphitePort = Port(2003)
  else:
    result.graphiteHost = splits[0]
    result.graphitePort = Port(parseBiggestInt(splits[1]))
  result.postfix = postfix
  result.prefix = prefix
  if tcpAddr != "":
    splits = tcpAddr.rsplit(':', maxSplit=1)
    if splits.len == 1:
      result.tcpHost = splits[0]
      result.tcpPort = Port(8126)
    else:
      result.tcpHost = splits[0]
      result.tcpPort = Port(parseBiggestInt(splits[1]))
    result.tcpEna = true
  else:
    result.tcpEna = false
  result.persistCountKeys = persistCountKeys
  for p in percentiles:
    if p.len > 0:
      result.percentiles.add(
        Percentile(
          flt: parseFloat(p.strip()),
          str: p.replace('.', '_')
        )
      )
  case logLevel.toUpperAscii()
  of "DEBUG":
    result.logLevel = logging.lvlDebug
  of "INFO":
    result.logLevel = logging.lvlInfo
  of "WARN", "WARNING":
    result.logLevel = logging.lvlWarn
  of "ERROR":
    result.logLevel = logging.lvlError

  case logTo.toLowerAscii()
  of "console":
    result.logFacility = LF_CONSOLE
  of "file":
    result.logFacility = LF_FILE
  of "rsyslog":
    result.logFacility = LF_RSYSLOG

  case fileRotationType.toLowerAscii()
  of "none":
    result.fileRotationType = FL_NONE
  of "hourly":
    result.fileRotationType = FL_HOUR
  of "daily":
    result.fileRotationType = FL_DAY
  of "weekly":
    result.fileRotationType = FL_WEEK
  result.fileMaxRotations = fileMaxRotations
  result.fileName = fileName
  result.rsysLogURL = rsysLogURL
  result.logFormat = logFormat
  if logName.len > 0:
    result.logName = logName
  else:
    result.logName = splitFile(getAppFilename()).name
  result.debug = debug
  echo "--- Current configuration ---"
  case result.logFacility:
  of LF_CONSOLE:
    echo "Logging to console"
  of LF_FILE:
    echo "Logging to file: " & fileName
  of LF_RSYSLOG:
    echo "Logging to RSysLog URL: " & rsysLogURL
  echo "address ", result.addressHost, ":", result.addressPort
  if result.tcpEna:
    echo "TCP address ", result.tcpHost, ":", result.tcpPort
  echo "graphite ", result.graphiteHost, ":", result.graphitePort
  echo "prefix ", result.prefix
  echo "postfix ", result.postfix
  echo "flush interval ", result.flushInterval
  echo "delete gauges ", result.deleteGauges
  echo "persist count keys ", result.persistCountKeys
  if result.percentiles.len > 0:
    for p in result.percentiles:
      echo "percentile ", p.str
  echo "---"
  if debug:
    echo "!!!! DEBUG DRY-RUN MODE !!!!"



proc `$`*(p: Percentile): string =
  p.str


proc readConfig*(): StatsDConfig =
  try:
    let conf = loadConfig("statsd.ini")
    result = initConfig(
      address = conf.getSectionValue("", "address", "0.0.0.0:8125"),
      deleteGauges = parseBool(conf.getSectionValue("", "delete-gauges", "true")),
      flushInterval = parseBiggestInt(conf.getSectionValue("", "flush-interval", "10")),
      graphite = conf.getSectionValue("", "graphite", "127.0.0.1:2003"),
      prefix = conf.getSectionValue("", "prefix", ""),
      postfix = conf.getSectionValue("", "postfix", ""),
      tcpAddr = conf.getSectionValue("", "tcpaddr", ""),
      persistCountKeys = parseBiggestInt(conf.getSectionValue("", "persist-count-keys", "60")),
      percentiles = conf.getSectionValue("", "percentiles", "").split(','),
      logLevel = conf.getSectionValue("", "log-level", "debug"),
      logTo = conf.getSectionValue("", "log-facility", "console"),
      fileName = conf.getSectionValue("", "log-filename", "./statsd.log"),
      fileMaxRotations = parseBiggestInt(conf.getSectionValue("", "log-max-rotations", "1")),
      fileRotationType = conf.getSectionValue("", "log-rotation-type", "none"),
      rsysLogURL = conf.getSectionValue("", "rsyslog-url", "unix:///dev/log"),
      logFormat = conf.getSectionValue("", "log-format", "%(asctime).%(msecs) %(process) %(levelname) %(filename):%(lineno)] %(name) %(tags) %(message)"),
      logName = conf.getSectionValue("", "log-name", ""),
      debug = parseBool(conf.getSectionValue("", "dry-run", "false"))
    )
  except IOError as e:
    echo "Error reading config (", e.msg, "). Using defaults."
    result = initConfig()
