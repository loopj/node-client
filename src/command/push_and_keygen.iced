{Base} = require './base'
log = require '../log'
session = require '../session'
{make_esc} = require 'iced-error'
log = require '../log'
{KeybasePushProofGen} = require '../sigs'
req = require '../req'
{env} = require '../env'
{prompt_passphrase} = require '../prompter'
{KeyManager} = require '../keymanager'
{E} = require '../err'
{athrow} = require('iced-utils').util
{env} = require '../env'
{User} = require '../user'
{make_email} = require '../util'

##=======================================================================

exports.Command = class Command extends Base

  #----------

  @OPTS :
    s :
      alias : "secret"
      action : "storeTrue"
      help : "push the secret key to the server"

  #----------

  constructor : (args...) ->
    super args...
    @_secret_only = false

  #----------

  use_session : () -> true

  #----------

  secret_only : () -> @_secret_only

  #----------

  sign : (cb) ->
    log.debug "+ Command::sign"
    em = make_email env().get_username()
    all_uids = @key.all_uids()
    if em in (e for uid in all_uids when (e = uid?.email))
      log.debug "| We can skip the sig, since the UID #{em} is already in the key"
      @sig = null
    else
      eng = new KeybasePushProofGen { km : @key }
      await eng.run defer err, @sig
    log.debug "- Command::sign"
    cb err

  #----------

  push : (cb) ->
    args = 
      is_primary : 1
      
    if @sig?
      args.sig_id_base = @sig.id
      args.sig_id_short = @sig.short_id
      args.sig = @sig.pgp

    args.public_key = @key.key_data().toString('utf8') unless @secret_only()
    args.private_key = @p3skb if @p3skb
    await req.post { endpoint : "key/add", args }, defer err
    cb err

  #----------

  load_key_manager : (cb) ->
    esc = make_esc cb, "KeyManager::load_secret"
    await KeyManager.load { fingerprint : @key.fingerprint() }, esc defer @keymanager
    cb null

  #----------

  package_secret_key : (cb) ->
    log.debug "+ package secret key"
    prompter = @prompt_passphrase.bind(@)
    await @keymanager.export_to_p3skb { prompter }, defer err, p3skb
    @p3skb = p3skb unless err?
    log.debug "- package secret key -> #{err?.message}"
    cb err

  #----------

  do_secret_key : (cb) ->
    esc = make_esc cb, "KeyManager::do_secret_key"
    await @should_push_secret esc defer go
    if go
      await @load_key_manager esc defer() unless @keymanager?
      await @package_secret_key esc defer()
    cb null

  #----------

  prompt_passphrase : (cb) ->
    args = 
      prompt : "Your key passphrase"
    await prompt_passphrase args, defer err, pp
    cb err, pp

  #----------

  prompt_new_passphrase : (cb) ->
    args = 
      prompt : "Your key passphrase (can be the same as your login passphrase)"
      confirm : prompt: "Repeat to confirm"
    await prompt_passphrase args, defer err, pp
    cb err, pp

  #----------

  do_key_gen : (cb) ->
    esc = make_esc cb, "do_key_gen"
    await @prompt_new_passphrase esc defer passphrase 
    log.debug "+ generating public/private keypair"
    await KeyManager.generate { passphrase }, esc defer @keymanager
    log.debug "- generated"
    log.debug "+ loading public key"
    await @keymanager.load_public esc defer @key
    log.debug "- loaded public key"
    cb null, @key

  #----------

  check_args : (cb) -> cb null
  should_push_secret : (cb) -> cb null, (@argv.secret or @secret_only())
  should_push : (cb) -> cb null, true

  #----------

  check_no_key : (cb) ->
    esc = make_esc cb, "check_no_key"
    await User.load { username : env().get_username() }, esc defer @me
    await @me.check_key { secret : false }, esc defer ckres
    err = null
    if ckres.remote and @argv.secret
      log.info "Public key already uploaded; pushing only secret key"
      @_secret_only = true
    else if ckres.remote and not(@argv.secret)
      err = new E.KeyExistsError "You already have a key registered; you must revoke first"
    cb err

  #----------

  run : (cb) ->
    esc = make_esc cb, "run"
    await @check_no_key esc defer()
    await @check_args esc defer()
    await @prepare_key esc defer()
    await @should_push esc defer go
    if go
      await session.login esc defer()
      await @sign esc defer()
      await @do_secret_key esc defer()
      await @push esc defer()
    log.info "success!"
    cb null

##=======================================================================

