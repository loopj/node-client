dv = require './decrypt_and_verify'
{add_option_dict} = require './argparse'
{env} = require '../env'
{BufferOutStream,BufferInStream} = require('iced-spawn')
{TrackSubSubCommand} = require '../tracksubsub'
log = require '../log'
{keypull} = require '../keypull'

##=======================================================================

exports.Command = class Command extends dv.Command

  #----------

  add_subcommand_parser : (scp) ->
    opts = 
      aliases : [ "dec" ]
      help : "decrypt a file"
    name = "decrypt"
    sub = scp.addParser name, opts
    add_option_dict sub, dv.Command.OPTS
    add_option_dict sub, {
      o:
        alias : "output"
        help : "output to the given file"
    }
    sub.addArgument [ "file" ], { nargs : '?' }
    return opts.aliases.concat [ name ]

  #----------

  do_output : (out) ->
    log.console.log out.toString( if @argv.base64 then 'base64' else 'binary' )

  #----------

  is_batch : () -> not(@argv.message?) and not(@argv.file?)

  #----------

  do_keypull : (cb) ->
    await keypull {stdin_blocked : @is_batch(), need_secret : true }, defer err
    @_ran_keypull = true
    cb err

  #----------

  make_gpg_args : () ->
    args = [ 
      "--decrypt" , 
      "--with-colons",   
      "--keyid-format", "long", 
      "--keyserver" , env().get_key_server(),
      "--keyserver-options", "auto-key-retrieve=1", # needed for GPG 1.4.x
      "--with-fingerprint"
      "--yes" # needed in the case of overwrite!
    ]
    args.push( "--keyserver-options", "debug=1")  if env().get_debug()
    args.push( "--output", o ) if (o = @argv.output)?
    gargs = { args }
    gargs.stderr = new BufferOutStream()
    if @argv.message
      gargs.stdin = new BufferInStream @argv.message 
    else if @argv.file?
      args.push @argv.file 
    else
      gargs.stdin = process.stdin
      @batch = true
    return gargs

##=======================================================================
