const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/ChromiumBridge/SidebarMediaBridge.swift'), 'utf8');
function script(name) {
  const match = source.match(new RegExp(`private static let ${name} = """\\n([\\s\\S]*?)\\n    """`));
  assert(match, `${name} is present`);
  return match[1].includes('\\(mediaMetadataScript)')
    ? match[1].replace('\\(mediaMetadataScript)', script('mediaMetadataScript')) : match[1];
}
function media(opts={}) {
  return {tagName: 'AUDIO', readyState: 4, ended: false, paused: false, muted: false, volume: 1,
          currentTime: 7, duration: 18, currentSrc: 'test-tone.wav', played: {length: 1},
          seekable: {length: 1, start: () => 0, end: () => 18},
          ownerDocument: {
            defaultView: {performance: {timeOrigin: 1000},
                          navigator: {mediaSession: {metadata: {title: 'Test Track', artist: 'Artist'}}}},
            pictureInPictureEnabled: true, pictureInPictureElement: null
          },
          ...opts};
}
function doc(items, frames=[]) {
  return {defaultView: {performance: {timeOrigin: 1000}},
          querySelectorAll: selector => selector === 'audio,video' ? items : frames};
}
const active = media();
const paused = media({paused: true, currentTime: 5, currentSrc: 'other.wav'});
const document = doc([paused, active]);
const navigator = {mediaSession: {metadata: null}};
const context = {document, navigator, Number};
const result = vm.runInNewContext(script('snapshotScript'), context);
assert.equal(result.title, 'Test Track');
assert.equal(result.artist, 'Artist');
assert.equal(result.index, 1);
assert.equal(result.currentTime, 7);
assert.equal(result.duration, 18);
assert.equal(result.seekEnd, 18);
assert.equal(result.topDocumentTimeOrigin, 1000);
assert.equal(result.mediaDocumentTimeOrigin, 1000);
assert.equal(result.canPictureInPicture, false, 'audio cannot enter video PiP');
const preload = media({paused: true, currentTime: 0, played: {length: 0}});
assert.equal(vm.runInNewContext(script('snapshotScript'),
  {document: doc([preload]), navigator, Number}), null,
  'a ready but never-started preload must not create a player');
const rewound = media({paused: true, currentTime: 0, played: {length: 1}});
assert.equal(vm.runInNewContext(script('snapshotScript'),
  {document: doc([rewound]), navigator, Number}).source, rewound.currentSrc,
  'a played source paused at zero remains available');
const lookup = vm.runInNewContext(script('mediaLookupScript'), context);
assert.equal(lookup('test-tone.wav', 1), active);
assert.equal(lookup('missing.wav', 1), null, 'stale source must not command another element');
assert.equal(lookup('', 0), paused);
const duplicate = media({currentSrc: 'test-tone.wav'});
const duplicateLookup = vm.runInNewContext(script('mediaLookupScript'),
  {document: doc([duplicate, active]), navigator, Number});
assert.equal(duplicateLookup('test-tone.wav', 1), active, 'exact index wins for duplicate source');
assert.equal(duplicateLookup('test-tone.wav', 4), null, 'ambiguous duplicate source must fail closed');
active.ended = true;
paused.ended = true;
assert.equal(vm.runInNewContext(script('snapshotScript'), context), null, 'ended media is removed');
const live = media({duration: Infinity, seekable: {length: 0}});
const liveResult = vm.runInNewContext(script('snapshotScript'), {document: doc([live]), navigator, Number});
assert.equal(liveResult.duration, null);
assert.equal(liveResult.seekStart, null);
const video = media({tagName: 'VIDEO', requestPictureInPicture: () => Promise.resolve()});
assert.equal(vm.runInNewContext(script('snapshotScript'),
  {document: doc([video]), navigator, Number}).canPictureInPicture, true);
function actionScript(operation, source='test-tone.wav', index=0,
                      topDocumentTimeOrigin=1000, mediaDocumentTimeOrigin=1000,
                      metadataIdentity=JSON.stringify(['Test Track', 'Artist', ''])) {
  const template = sourceCodeActionTemplate();
  return template
    .replace('\\(mediaLookupScript)', script('mediaLookupScript'))
    .replace('\\(mediaMetadataScript)', script('mediaMetadataScript'))
    .replace('\\(quoted(metadataIdentity))', JSON.stringify(metadataIdentity))
    .replace('\\(quoted(source))', JSON.stringify(source))
    .replace('\\(index)', String(index))
    .replace('\\(topDocumentTimeOrigin)', String(topDocumentTimeOrigin))
    .replace('\\(mediaDocumentTimeOrigin)', String(mediaDocumentTimeOrigin))
    .replace('\\(operation)', operation);
}
function sourceCodeActionTemplate() {
  const match = source.match(/let script = """\n([\s\S]*?)\n        """/);
  assert(match, 'perform action script is present');
  return match[1];
}
function operationForAction(action) {
  const match = source.match(new RegExp(`case \\.${action}[\\s\\S]*?operation = "([^"\\n]+)"`));
  assert(match, `${action} operation is present`);
  return match[1];
}
(async () => {
  const rejected = media({paused: true, play: () => Promise.reject(new Error('blocked'))});
  const playOperation = operationForAction('playPause');
  assert.equal((await vm.runInNewContext(actionScript(playOperation),
    {document: doc([rejected]), navigator, Number})).ok, false,
    'rejected play promise must be reported');
  const accepted = media({paused: true, play: () => Promise.resolve()});
  assert.equal((await vm.runInNewContext(actionScript(playOperation),
    {document: doc([accepted]), navigator, Number})).ok, true);
  let replacementPlayCount = 0;
  const replacement = media({paused: true, play: async () => { replacementPlayCount++; }});
  let finishConnectionSetup;
  const connectionReady = new Promise(resolve => { finishConnectionSetup = resolve; });
  const oldAction = actionScript(playOperation, result.source, result.index,
                                result.topDocumentTimeOrigin, result.mediaDocumentTimeOrigin,
                                result.metadataIdentity);
  let actionDocument = document;
  const delayedAction = (async () => {
    await connectionReady;
    return vm.runInNewContext(oldAction, {document: actionDocument, navigator, Number});
  })();
  const reloaded = doc([replacement]);
  // Recreate the same source and index while connection setup is awaiting.
  // Source validation alone would otherwise play this replacement element.
  reloaded.querySelectorAll = selector => selector === 'audio,video' ? [paused, replacement] : [];
  reloaded.defaultView.performance.timeOrigin = 2000;
  replacement.ownerDocument.defaultView.performance.timeOrigin = 2000;
  actionDocument = reloaded;
  finishConnectionSetup();
  assert.equal((await delayedAction).ok, false,
    'same-URL reload during delayed connection setup must reject the old action');
  assert.equal(replacementPlayCount, 0);
  reloaded.defaultView.performance.timeOrigin = 1000;
  assert.equal((await vm.runInNewContext(actionScript(playOperation, result.source, result.index),
    {document: reloaded, navigator, Number})).ok, false,
    'reloading only the media owner frame must also reject the stale action');
  assert.equal(replacementPlayCount, 0);
  const seekOperation = operationForAction('seek').replace('\\(seconds)', '100');
  const sameStream = media({currentSrc: 'blob:same-stream'});
  const streamContext = {document: doc([sameStream]), navigator, Number};
  const oldTrack = vm.runInNewContext(script('snapshotScript'), streamContext);
  let releaseTrackSetup;
  const trackSetup = new Promise(resolve => { releaseTrackSetup = resolve; });
  const delayedTrackSeek = (async () => {
    await trackSetup;
    return vm.runInNewContext(actionScript(seekOperation, oldTrack.source, oldTrack.index,
      oldTrack.topDocumentTimeOrigin, oldTrack.mediaDocumentTimeOrigin, oldTrack.metadataIdentity), streamContext);
  })();
  // Change only raw album metadata: same element/blob/index/documents and
  // the same displayed title/artist still represent a different track.
  sameStream.ownerDocument.defaultView.navigator.mediaSession.metadata.album = 'New album';
  const nextTrack = vm.runInNewContext(script('snapshotScript'), streamContext);
  assert.equal(nextTrack.title, oldTrack.title);
  assert.equal(nextTrack.artist, oldTrack.artist);
  assert.notEqual(nextTrack.metadataIdentity, oldTrack.metadataIdentity);
  releaseTrackSetup();
  assert.equal((await delayedTrackSeek).ok, false,
    'metadata-only replacement must reject a delayed old-track seek');
  assert.equal(sameStream.currentTime, 7, 'stale seek changed a new metadata track');
  assert.equal((await vm.runInNewContext(actionScript(seekOperation, nextTrack.source, nextTrack.index,
    nextTrack.topDocumentTimeOrigin, nextTrack.mediaDocumentTimeOrigin, nextTrack.metadataIdentity), streamContext)).ok, true);
  assert.equal(sameStream.currentTime, 18, 'a fresh metadata identity should allow seeking');
    const oversized = media();
  const oversizedContext = {document: doc([oversized]), navigator, Number};
  oversized.ownerDocument.defaultView.navigator.mediaSession.metadata.title = 'x'.repeat(4096);
  const maximumIdentity = vm.runInNewContext(script('snapshotScript'), oversizedContext);
  assert(maximumIdentity, 'the bounded maximum metadata field should be supported exactly');
  assert.equal(JSON.parse(maximumIdentity.metadataIdentity)[0].length, 4096);
  oversized.ownerDocument.defaultView.navigator.mediaSession.metadata.title += 'x';
  assert.equal(vm.runInNewContext(script('snapshotScript'), oversizedContext), null,
    'oversized page metadata should fail closed instead of inflating polling responses');
  assert.equal((await vm.runInNewContext(actionScript(seekOperation, maximumIdentity.source, maximumIdentity.index,
    maximumIdentity.topDocumentTimeOrigin, maximumIdentity.mediaDocumentTimeOrigin, maximumIdentity.metadataIdentity), oversizedContext)).ok, false);
  assert.equal(oversized.currentTime, 7, 'oversized replacement metadata must reject an old seek');
    const seekable = media();
  assert.equal((await vm.runInNewContext(actionScript(seekOperation),
    {document: doc([seekable]), navigator, Number})).ok, true);
  assert.equal(seekable.currentTime, 18, 'seek must clamp to seekable end');
  const unseekable = media({seekable: {length: 0}});
  assert.equal((await vm.runInNewContext(actionScript(seekOperation),
    {document: doc([unseekable]), navigator, Number})).ok, false);
  const pipOperation = operationForAction('pictureInPicture');
  let entered = 0;
  const pipVideo = media({tagName: 'VIDEO', requestPictureInPicture: async () => { entered++; }});
  assert.equal((await vm.runInNewContext(actionScript(pipOperation),
    {document: doc([pipVideo]), navigator, Number})).ok, true);
  assert.equal(entered, 1, 'PiP enters via the selected video');
  pipVideo.ownerDocument.pictureInPictureElement = pipVideo;
  pipVideo.ownerDocument.exitPictureInPicture = async () => { entered--; };
  assert.equal((await vm.runInNewContext(actionScript(pipOperation),
    {document: doc([pipVideo]), navigator, Number})).ok, true);
  assert.equal(entered, 0, 'PiP exits via the selected video document');
  assert.equal((await vm.runInNewContext(actionScript(pipOperation),
    {document: doc([media()]), navigator, Number})).ok, false,
    'audio must not attempt video PiP');
  const blockedPip = media({tagName: 'VIDEO',
    requestPictureInPicture: () => Promise.reject(new Error('blocked'))});
  assert.equal((await vm.runInNewContext(actionScript(pipOperation),
    {document: doc([blockedPip]), navigator, Number})).ok, false,
    'rejected PiP promise must be reported');
  console.log('Sidebar media bridge JavaScript checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
