import std/[tables, nativesockets, asyncnet, exitprocs, asyncdispatch, strutils, sets, times, algorithm, sequtils, math]
import ./private/config


const MAX_UDP_SIZE = 1472
const MAX_TCP_SIZE = 4096
const SLEEP_TIME = 500


type  
  StatsD = object
    config: StatsDConfig
    udpSock: AsyncSocket
    tcpSock: AsyncSocket
    graphiteSock: AsyncSocket
    graphiteConnected: bool
    counters: Table[string, float64]
    gauges: Table[string, float64]
    countInactivity: Table[string, int64]
    sets: Table[string, HashSet[string]]
    timers: Table[string, seq[float64]]


var running: bool = true
proc atExit() {.noconv.} =
  running = false
  echo "Stopping application"

var self {.noinit.}: StatsD

func sanitizeBucket(bucket: string): string =
  var ns = newStringOfCap(bucket.len)

  for c in bucket:
    case c
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9':
      ns.add(c)
    of '-', '.', '_':
      ns.add(c)
    of ' ':
      ns.add('_')
    of '/':
      ns.add('-')
    else:
      discard
  return ns


proc processData(data: string) =
  var split = data.split('|', maxSplit=2)
  if split.len < 2:
    echo "ERROR: parse error for ", data
    return
  let keyVal = split[0]
  let typeCode = split[1]
  var sampling = 1.float32
  if typeCode == "c" or typeCode == "ms":
    if split.len == 3 and split[2].len > 0 and split[2][0] == '@':
      try:
        sampling = parseFloat(split[2][1 .. split[2].high]).float32
      except ValueError:
        echo "ERROR: Float parsing falied for ", split[2]
        return
  split = keyVal.split(':', maxSplit = 1)
  if split.len < 2:
    echo "ERROR: parse error for ", data
    return
  let name = split[0]
  var val = split[1]
  if val.len == 0:
    echo "ERROR: parse error for ", data
    return
  var floatVal: float64
  var strVal: string
  case typeCode
  of "c":
    try:
      floatVal = val.parseFloat()
    except ValueError:
      echo "ERROR: Float parsing falied for ", val
      return
  of "g":
    if val[0] in ['+', '-']:
      strVal = val[0 .. 0]
      val = val[1 .. val.high]
    try:
      floatVal = val.parseFloat()
    except ValueError:
      echo "ERROR: Float parsing falied for ", val
      return
  of "s":
    strVal = val
  of "ms":
    try:
      floatVal = val.parseFloat()
    except ValueError:
      echo "ERROR: Float parsing falied for ", val
      return
  else:
    echo "ERROR: Unknown type code ", typeCode, " for metric ", name
    return

  let bucket = self.config.prefix & sanitizeBucket(name) & self.config.postfix 
  case typeCode:
  of "ms":
    self.timers.mgetOrPut(bucket, @[]).add(floatVal)
  of "g":
    var gaugeValue = self.gauges.getOrDefault(bucket, 0.float64)
    if strVal == "":
      gaugeValue = floatVal
    elif strVal == "+":
      if floatVal > float64.high - gaugeValue:
        gaugeValue = float64.high
      else:
        gaugeValue += floatVal
    elif strVal == "-":
      if floatVal > gaugeValue:
        gaugeValue = 0
      else:
        gaugeValue -= floatVal
    self.gauges[bucket] = gaugeValue
  of "c":
    self.counters.mgetOrPut(bucket, 0) += floatVal * (1.float64/sampling)
  of "s":
    self.sets.mgetOrPut(bucket, initHashSet[string](0)).incl(strVal)


proc udpListener() {.async.} =
  self.udpSock.bindAddr(self.config.addressPort, self.config.addressHost)
  while running:
    var (recvData, _, _) = await self.udpSock.recvFrom(MAX_UDP_SIZE)
    while true:
      let slashN = recvData.split('\n', maxSplit=1)
      if slashN.len == 1:
        break
      processData(slashN[0])
      recvData = slashN[1]
  self.udpSock.close()


proc tcpReader(sock: AsyncSocket) {.async.} =
  while running:
    var recvData = await sock.recv(MAX_TCP_SIZE)
    if recvData.len == 0:
      echo "Socket closed"
      break
    while true:
      let slashN = recvData.split('\n', maxSplit=1)
      if slashN.len == 1:
        break
      processData(slashN[0])
      recvData = slashN[1]
  sock.close()


proc tcpListener() {.async.} =
  if self.config.tcpEna:
    self.tcpSock.bindAddr(self.config.tcpPort, self.config.tcpHost)
    self.tcpSock.listen()
    try:
      while true:
        let newSock = await self.tcpSock.accept()
        discard tcpReader(newSock)
    except:
      echo "TCP failed"
    self.tcpSock.close()


proc processBuf(buffer: var string, addition: string): bool =
  if buffer.len + addition.len <= MAX_UDP_SIZE:
    buffer.add(addition)
    result = true
  else:
    result = false


proc processCounters(buffer: var string, now: int): int =
  result = 0
  var toDelete: seq[string]
  for bucket, value in self.counters.pairs:
    if buffer.processBuf(bucket & " " & $value & " " & $now & "\n"):
      toDelete.add(bucket)
      result.inc
    else:
      break
  for bucket in toDelete:
    self.counters.del(bucket)
  toDelete.setLen(0)
  for bucket, purgeCount in self.countInactivity.pairs:
    if purgeCount > 0:
      if buffer.processBuf(bucket & " 0 " & $now & "\n"):
        result.inc
        self.countInactivity[bucket].inc
        if self.countInactivity[bucket] > self.config.persistCountKeys:
          toDelete.add(bucket)
      else:
        break
  for bucket in toDelete:
    self.countInactivity.del(bucket)


proc processGauges(buffer: var string, now: int): int =
  result = 0
  var valuestr: string
  var gCopy = self.gauges
  for bucket, value in gCopy.pairs:
    valuestr = if float(int(value)) == value: $int(value) else: $value
    if buffer.processBuf(bucket & " " & valuestr & " " & $now & "\n"):
      result.inc
      if self.config.deleteGauges:
        self.gauges.del(bucket)
    else:
      break


proc processSets(buffer: var string, now: int): int =
  result = 0
  var toDelete: seq[string]
  for bucket, dataset in self.sets.pairs:
    if buffer.processBuf(bucket & " " & $dataset.len & " " & $now & "\n"):
      result.inc
      toDelete.add(bucket)
    else:
      break
  for bucket in toDelete:
    self.sets.del(bucket)


proc processTimers(buffer: var string, now: int): int =
  result = 0
  var toDelete: seq[string]
  var tmpStr: string
  for bucket, timer in self.timers.mpairs:
    let bwp = bucket[0 .. bucket.high-self.config.postfix.len]
    timer.sort(order=Ascending)
    let minTimer = timer[0]
    let maxTimer = timer[timer.high]
    let count = timer.len
    let sum: float64 = timer.foldl(a+b, 0.float64)
    let mean = sum/count.float64
    var maxAtThreshold = maxTimer
    for p in self.config.percentiles:
      if count > 1:
        let abs: float64 = (if p.flt >= 0: p.flt else: 100+p.flt)
        var idx: int = int(floor(((abs / 100.0) * count.float64) + 0.5))
        if p.flt >= 0:
          idx.dec
        maxAtThreshold = timer[idx]
      if p.flt >= 0:
        tmpStr.add(bwp & ".uppper_" & p.str & self.config.postfix & " " & $maxAtThreshold & " " & $now & "\n")
      else:
        tmpStr.add(bwp & ".lower_" & p.str[1 .. p.str.high] & self.config.postfix & " " & $maxAtThreshold & " " & $now & "\n")
    tmpStr.add(bwp & ".mean" & self.config.postfix & " " & $mean & " " & $now & "\n")
    tmpStr.add(bwp & ".upper" & self.config.postfix & " " & $maxTimer & " " & $now & "\n")
    tmpStr.add(bwp & ".lower" & self.config.postfix & " " & $minTimer & " " & $now & "\n")
    tmpStr.add(bwp & ".count" & self.config.postfix & " " & $count & " " & $now & "\n")
    if buffer.processBuf(tmpStr):
      result.inc
      toDelete.add(bucket)
    else:
      break
  
  for bucket in toDelete:
    self.timers.del(bucket)


proc reconnectGraphite() {.async.} =
  if not self.graphiteConnected:
    try:
      await self.graphiteSock.connect(self.config.graphiteHost, self.config.graphitePort)
      self.graphiteConnected = true
    except:
      self.graphiteConnected = false


proc onTimerEvent() {.async.} =
  let now = getTime().toUnix()
  var num: int = 0
  var buffer: seq[string]
  if self.graphiteConnected:
    while true:
      var b: string
      num = 0
      num.inc(processCounters(b, now))
      num.inc(processGauges(b, now))
      num.inc(processTimers(b, now))
      num.inc(processSets(b, now))
      if b.len == 0:
        break
      buffer.add(b)
    try:
      for b in buffer:
        await self.graphiteSock.send(b, flags={})
    except Exception as e:
      self.graphiteConnected = false
      echo "ERROR: ", e.msg
  else:
    await reconnectGraphite()


proc timer() {.async.} =
  var timeout = 0
  while running:
    await sleepAsync(SLEEP_TIME)
    timeout += SLEEP_TIME
    timeout = timeout.mod(self.config.flushInterval)
    if timeout == 0:
      await onTimerEvent()
  await onTimerEvent()


proc initStatsD(cfg: StatsDConfig): StatsD =
  result.config = cfg
  result.udpSock = newAsyncSocket(sockType=SOCK_DGRAM, protocol=IPPROTO_UDP)
  if cfg.tcpEna:
    result.tcpSock = newAsyncSocket(buffered=false)
  result.graphiteSock = newAsyncSocket(buffered=false)


proc main(cfg: StatsDConfig) {.async.} =
  self = initStatsD(cfg)
  let ulistenerFuture {.used.} = udpListener()
  let tlistenerFuture {.used.} = tcpListener()
  await reconnectGraphite()
  let timerFuture {.used.} = timer()
  while running:
    await asyncdispatch.sleepAsync(100)
  #await ulistener
  #await tlistener
  await timerFuture


when isMainModule:
  let cfg = readConfig()
  echo("Starting application")
  addExitProc(atExit)
  setControlCHook(atExit)
  waitFor(main(cfg))
