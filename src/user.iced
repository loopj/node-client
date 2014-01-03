
req = require './req'
{gpg} = require 'gpg-wrapper'
db = require './db'
{constants} = require './constants'
{make_esc} = require 'iced-error'
{E} = require './err'
deepeq = require 'deep-equal'
{SigChain} = require './sigchain'
log = require './log'
{UntrackerProofGen,TrackerProofGen} = require './sigs'
{KeyManager} = require './keymanager'
{session} = require './session'
{env} = require './env'
{TrackWrapper} = require './trackwrapper'

##=======================================================================

filter = (d, v) ->
  out = {}
  for k in v when d?
    out[k] = d[k]
  return out

##=======================================================================

exports.User = class User 

  #--------------

  @FIELDS : [ "basics", "public_keys", "id", "sigs" ]

  #--------------

  constructor : (args) ->
    for k in User.FIELDS
      @[k] = args[k]
    @_dirty = false
    @sig_chain = null

  #--------------

  set_is_self : (b) -> @_is_self = b

  #--------------

  to_obj : () -> 
    out = {}
    for k in User.FIELDS
      out[k] = @[k]
    return out

  #--------------

  name : () -> { type : constants.lookups.username, name : @basics.username }

  #--------------

  store : (force_store, cb) ->
    err = null
    un = @username()
    if force_store or @_dirty
      log.debug "+ #{un}: storing user to local DB"
      await db.put { key : @id, value : @to_obj(), name : @name() }, defer err
      log.debug "- #{un}: stored user to local DB"
    if @sig_chain? and not err?
      log.debug "+ #{un}: storing signature chain"
      await @sig_chain.store defer err
      log.debug "- #{un}: stored signature chain"
    cb err

  #--------------

  update_fields : (remote) ->
    for k in User.FIELDS
      @update_field remote, k
    true

  #--------------

  update_field : (remote, which) ->
    if not (deepeq(@[which], remote[which]))
      @[which] = remote[which]
      @_dirty = true

  #--------------

  load_sig_chain_from_storage : (cb) ->
    err = null
    log.debug "+ load sig chain from local storage"
    @last_sig = @sigs?.last or { seqno : 0 }
    if (ph = @last_sig.payload_hash)?
      log.debug "| loading sig chain w/ payload hash #{ph}"
      await SigChain.load @id, ph, defer err, @sig_chain
    else
      @sig_chain = new SigChain @id
    log.debug "- loaded sig chain from local storage"
    cb err

  #--------------

  load_full_sig_chain : (cb) ->
    log.debug "+ load full sig chain"
    sc = new SigChain @id
    await sc.update null, defer err
    @sig_chain = sc unless err?
    log.debug "- loaded full sig chain"
    cb err

  #--------------

  update_sig_chain : (remote, cb) ->
    seqno = remote?.sigs?.last?.seqno
    log.debug "+ update sig chain; seqno=#{seqno}"
    await @sig_chain.update seqno, defer err, did_update
    if did_update
      @sigs.last = @sig_chain.last().export_to_user()
      log.debug "| update sig_chain last link to #{JSON.stringify @sigs}"
      @_dirty = true
    log.debug "- updated sig chain"
    cb err

  #--------------

  update_with : (remote, cb) ->
    err = null
    log.debug "+ updating local user w/ remote"

    a = @basics?.id_version
    b = remote?.basics?.id_version

    if not b? or a > b
      err = new E.VersionRollbackError "Server version-rollback suspected: Local #{a} > #{b}"
    else if not a? or a < b
      log.debug "| version update needed: #{a} vs. #{b}"
      @update_fields remote
    else if a isnt b
      err = new E.CorruptionError "Bad ids on user objects: #{a.id} != #{b.id}"

    if not err?
      await @update_sig_chain remote, defer err

    log.debug "- finished update"

    cb err

  #--------------

  @load : ({username}, cb) ->
    esc = make_esc cb, "User::load"
    log.debug "+ #{username}: load user"
    await User.load_from_server {username}, esc defer remote
    await User.load_from_storage {username}, esc defer local
    changed = true
    force_store = false
    if local?
      await local.update_with remote, esc defer()
    else if remote?
      local = remote
      await local.load_full_sig_chain esc defer()
      force_store = true
    else
      err = new E.UserNotFoundError "User #{username} wasn't found"
    if not err?
      await local.store force_store, esc defer()
    log.debug "- #{username}: loaded user"
    cb err, local

  #--------------

  @load_from_server : ({username}, cb) ->
    log.debug "+ #{username}: load user from server"
    args = 
      endpoint : "user/lookup"
      args : {username }
    await req.get args, defer err, body
    ret = null
    unless err?
      ret = new User body.them
    log.debug "- #{username}: loaded user from server"
    cb err, ret

  #--------------

  @load_from_storage : ({username}, cb) ->
    log.debug "+ #{username}: load user from local storage"
    ret = null
    await db.lookup { type : constants.lookups.username, name: username }, defer err, row
    if not err? and row?
      ret = new User row.value
      await ret.load_sig_chain_from_storage defer err
      if err?
        ret = null
    log.debug "- #{username}: loaded user from local storage"
    cb err, ret

  #--------------

  fingerprint : (upper_case = false) ->
    unless @_fingerprint?
      @_fingerprint =
        lc : @public_keys?.primary?.key_fingerprint?.toLowerCase()
      @_fingerprint.uc = @_fingerprint.lc?.toUpperCase()
    return @_fingerprint[if upper_case then 'uc' else 'lc']

  #--------------

  query_key : ({secret}, cb) ->
    if (fp = @fingerprint(true))?
      args = [ "-" + (if secret then 'K' else 'k'), fp ]
      await gpg { args, quiet : true }, defer err, out
      if err?
        err = new E.NoLocalKeyError (
          if @_is_self then "You don't have a local key!"
          else "the user #{@username()} doesn't have a local key"
        )
    else
      err = new E.NoRemoteKeyError (
        if @_is_self then "You don't have a registered remote key! Try `keybase push`"
        else "the user #{@username()} doesn't have a remote key"
      )
    cb err

  #--------------

  @load_me : (cb) ->
    esc = make_esc cb, "User::load_me"
    log.debug "+ User::load_me"
    await User.load { username : env().get_username() }, esc defer me
    me.set_is_self true
    await me.check_public_key esc defer()
    await me.verify esc defer()
    log.debug "- User::load_me"
    cb null, me

  #--------------

  check_public_key : (cb) ->
    un = @username()
    log.debug "+ #{un}: checking public key"
    await @query_key { secret : false }, defer err
    log.debug "- #{un}: checked public key"
    cb err

  #--------------

  load_public_key : (cb) ->
    err = null
    await KeyManager.load @fingerprint(), defer err, @km unless @km?
    cb err, @km

  #--------------

  username : () -> @basics.username

  #--------------

  import_public_key : (cb) ->
    un = @username()
    log.debug "+ #{un}: import public key"
    uid = @id
    found = false
    fingerprint = @fingerprint() # lower case!
    await @query_key { secret : false }, defer err
    if not err? 
      log.debug "| found locally"
      await db.get_import_state { uid, fingerprint }, defer err, state
      log.debug "| read state from DB as #{state}"
      found = (state isnt constants.import_state.TEMPORARY)
    else if not (err instanceof E.NoLocalKeyError)? then # noops
    else if not (data = @public_keys?.primary?.bundle)?
      err = new E.ImportError "no public key found for #{un}"
    else
      state = constants.import_state.TEMPORARY
      log.debug "| temporarily importing key to local GPG"
      await db.log_key_import { uid, state, fingerprint }, defer err
      unless err?
        args = [ "--import" ]
        await gpg { args, stdin : data, quiet : true }, defer err, out
        if err?
          err = new E.ImportError "#{un}: key import error: {err.message}"
    log.debug "- #{un}: imported public key (found=#{found})"
    cb err, found

  #--------------

  commit_key : (cb) ->
    await db.log_key_import { 
      uid : @id
      state : constants.import_state.FINAL
      fingerprint : @fingerprint()
    }, defer err
    cb err

  #--------------

  remove_key : (cb) ->
    un = @username()
    uid = @id
    fingerprint = @fingerprint() # lowecase case!
    esc = make_esc cb, "SigChain::remove_key"
    log.debug "+ #{un}: remove temporarily imported public key"
    args = [ "--batch", "--delete-keys", @fingerprint(true) ]
    state = constants.import_state.CANCELED
    await gpg { args }, esc defer()
    await db.log_key_import { uid, state, fingerprint }, esc defer()
    log.debug "- #{un}: removed temporarily imported public key"
    cb null

  #--------------

  check_remote_proofs : (skip, cb) ->
    await @sig_chain.check_remote_proofs { skip, username : @username() }, defer err, warnings
    cb err, warnings

  #--------------

  # Also serves to compress the public signatures into a usable table.
  verify : (cb) ->
    await @sig_chain.verify_sig { username : @username() }, defer err
    cb err

  #--------------

  gen_remote_proof_gen : ({klass, remote_username}, cb) ->
    esc = make_esc cb, "User::gen_remote_proof_gen"
    await @load_public_key esc defer()
    arg =  { @km, remote_username }
    g = new klass arg
    cb null, g

  #--------------

  gen_track_proof_gen : ({uid, track_obj, untrack_obj}, cb) ->
    esc = make_esc cb, "User::gen_track_proof_gen"
    await @load_public_key esc defer()
    last_link = @sig_chain?.last()
    klass = if untrack_obj? then UntrackerProofGen else TrackerProofGen
    arg = 
      km : @km
      seqno : (if last_link? then (last_link.seqno() + 1) else 1)
      prev : (if last_link? then last_link.id else null)
      uid : uid
    arg.track = track_obj if track_obj?
    arg.untrack = untrack_obj if untrack_obj?
    g = new klass arg
    cb null, g

  #--------------

  assert_tracking : (them, cb) ->
    await TrackWrapper.load { tracker : @, trackee : them }, defer err, trackw
    if not err? and not trackw.is_tracking()
      err = new E.UntrackError "You're not tracking '#{them.username()}'!"
    cb err

  #--------------

  gen_track_obj : () ->

    pkp = @public_keys.primary
    out =
      basics : filter @basics, [ "id_version", "last_id_change", "username" ]
      id : @id
      key : filter pkp, [ "kid", "key_fingerprint" ]
      seq_tail : @sig_chain?.last().to_track_obj()
      remote_proofs : @sig_chain?.remote_proofs_to_track_obj()
    out

  #--------------

  gen_untrack_obj : () ->

    pkp = @public_keys.primary
    out =
      basics : filter @basics, [ "id_version", "last_id_change", "username" ]
      id : @id
      key : filter pkp, [ "kid", "key_fingerprint" ]
    out

##=======================================================================

