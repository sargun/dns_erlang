-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-record(dnssec_test_sample, {
	  zonename,
	  alg,
	  nsec3,
	  alg_id,
	  alg_atom,
	  inception,
	  expiration,
	  zsk_pl,
	  ksk_pl,
	  rr_src,
	  rr_clean
	 }).

gen_nsec_test_() ->
    [ {ZoneName,
       ?_test(
	  begin
	      RRClean = [ RR || #dns_rr{type = Type} = RR <- RRSrc,
				Type =/= nsec ],
	      NSEC = lists:sort(
		       lists:foldr(
			 fun(#dns_rr{data = Data}=RR, Acc) ->
				 Bin = dns:encode_rrdata(in, Data),
				 NewData = dns:decode_rrdata(in, nsec, Bin),
				 [ RR#dns_rr{data = NewData} | Acc ]
			 end, [], gen_nsec(RRClean))),
	      SrcNSEC = lists:sort([ RR || #dns_rr{type = nsec} = RR <- RRSrc ]),
	      ?assertEqual(SrcNSEC, NSEC)
	  end
	 )}
      || #dnssec_test_sample{zonename = ZoneName,
			     nsec3 = undefined,
			     rr_src = RRSrc} <- helper_test_samples() ].

verify_rrset_test_() ->
    [ {Name, ?_assert(verify_rrsig(RRSig, RRSet, DNSKeys, Opts))}
      || {Name, RRSig, RRSet, DNSKeys, Opts} <- helper_verify_rrset_test_cases() ].
    
zone_test_() ->
    [ {helper_fmt("Build Zone ~s", [ZoneName]),
       ?_test(
	  begin
	      ZoneNameB = iolist_to_binary(ZoneName),
	      %% Add DNS keys
	      ZSKAlg = proplists:get_value(alg, ZSKPL),
	      ZSKPrivKey = helper_samplekeypl_to_privkey(ZSKPL),
	      ZSKPubKey = helper_samplekeypl_to_pubkey(ZSKPL),
	      ZSKPubKeyBin = helper_pubkey_to_dnskey_pubkey(Alg, ZSKPubKey),
	      ZSKAlgNo = dns:encode_alg(proplists:get_value(alg, ZSKPL)),
	      ZSKFlags = proplists:get_value(flags, ZSKPL),
	      ZSKKey0 = #dns_rrdata_dnskey{flags = ZSKFlags,
					   protocol = 3,
					   alg = ZSKAlgNo,
					   public_key = ZSKPubKeyBin},
	      ZSKKey = add_keytag_to_dnskey(ZSKKey0),
	      KSKAlg = proplists:get_value(alg, KSKPL),
	      KSKPrivKey = helper_samplekeypl_to_privkey(KSKPL),
	      KSKPubKey = helper_samplekeypl_to_pubkey(KSKPL),
	      KSKPubKeyBin = helper_pubkey_to_dnskey_pubkey(Alg, KSKPubKey),
	      KSKAlgNo = dns:encode_alg(proplists:get_value(alg, KSKPL)),
	      KSKFlags = proplists:get_value(flags, KSKPL),
	      KSKKey0 = #dns_rrdata_dnskey{flags = KSKFlags,
					   protocol = 3,
					   alg = KSKAlgNo,
					   public_key = KSKPubKeyBin},
	      KSKKey = add_keytag_to_dnskey(KSKKey0),
	      DNSKeyTmpl = #dns_rr{name = iolist_to_binary(ZoneName),
				   type = dnskey,
				   class = in,
				   ttl = 3600},
	      RRDNSKey = [ DNSKeyTmpl#dns_rr{data = KSKKey},
			   DNSKeyTmpl#dns_rr{data = ZSKKey} | RRClean ],
	      %% Add NSEC / NSEC3
	      RRNSEC = case NSEC3 of
			   undefined ->
			       gen_nsec(RRDNSKey) ++ RRDNSKey;
			   #dns_rrdata_nsec3param{} = Param ->
			       RRNSEC3 = [#dns_rr{name = ZoneNameB,
						  type = nsec3param,
						   ttl = 0, 
						  data = Param}|RRDNSKey],
			       gen_nsec3(RRNSEC3) ++ RRNSEC3
		       end,
	      RRDECENC = lists:map(
			   fun(#dns_rr{class = Class,
				       type = Type,
				       data = Data} = RR) ->
				   Bin = dns:encode_rrdata(in, Data),
				   NewData = dns:decode_rrdata(Class, Type, Bin),
				   RR#dns_rr{data=NewData}
			   end, RRNSEC),
	      %% Add RRSIG
	      Opts = [{inception, I}, {expiration, E}],
	      RRSigsZSK = sign_rr(RRDECENC, ZoneNameB,
				  ZSKKey#dns_rrdata_dnskey.key_tag,
				  ZSKAlg, ZSKPrivKey, Opts),
	      RRDNSKeys = [ RR || #dns_rr{type=dnskey} = RR <- RRDECENC ],
	      RRSigsKSK = sign_rr(RRDNSKeys, ZoneNameB,
				  KSKKey#dns_rrdata_dnskey.key_tag,
				  KSKAlg, KSKPrivKey, Opts),
	      RRFinal = RRSigsKSK ++ RRSigsZSK ++ RRDECENC,
	      GeneratedRR = lists:sort(
			      [ RR#dns_rr{name = normalise_dname(Name)}
				|| #dns_rr{name = Name} = RR <- RRFinal]
			     ),
	      SampleRR = lists:sort(
			   [ RR#dns_rr{name = normalise_dname(Name)}
			     || #dns_rr{name = Name} = RR <- RRSrc]
			  ),
	      ?assertEqual(GeneratedRR, SampleRR)
	  end )}
      || #dnssec_test_sample{zonename = ZoneName,
			     alg = rsa = Alg,
			     inception = I,
			     expiration = E,
			     nsec3 = NSEC3,
			     zsk_pl = ZSKPL,
			     ksk_pl = KSKPL,
			     rr_clean = RRClean,
			     rr_src = RRSrc} <- helper_test_samples() ].

test_sample_keys_test_() ->
    Keys = lists:foldl(fun(#dnssec_test_sample{alg = Alg,
					       zsk_pl = A, 
					       ksk_pl = B}, Acc) ->
			       [ {Alg, A}, {Alg, B} | Acc ]
		       end, [], helper_test_samples()),
    [ ?_assert(test_sample_key(Key)) || Key <- Keys ].

test_sample_key({Alg, Proplist}) ->
    PrivKey = helper_samplekeypl_to_privkey(Proplist),
    PubKey = helper_samplekeypl_to_pubkey(Proplist),
    test_sample_key(Alg, PrivKey, PubKey).

test_sample_key(dsa, PrivKey, PubKey) ->
    Sample = <<4:32,"1234">>,
    Sig = crypto:dss_sign(Sample, PrivKey),
    SigSize = byte_size(Sig),
    crypto:dss_verify(Sample, <<SigSize:32, Sig/binary>>, PubKey);
test_sample_key(rsa, PrivKey, PubKey) ->
    Sample = <<4:32,"1234">>,
    Cipher = crypto:rsa_private_encrypt(Sample, PrivKey, rsa_pkcs1_padding),
    Sample =:= crypto:rsa_public_decrypt(Cipher, PubKey, rsa_pkcs1_padding).

dnskey_pubkey_gen_test_() ->
    [ {ZoneName,
       ?_test(
	  begin
	      DnsKeyRR = lists:sort([ RR || #dns_rr{type=dnskey} = RR <- RRs ]),
	      Generated = lists:sort(
			    lists:map(
			      fun(PL) ->
				      PubKey = helper_samplekeypl_to_pubkey(PL),
				      AlgNo = dns:encode_alg(
						proplists:get_value(alg, PL)),
				      Flags = proplists:get_value(flags, PL),
				      Key = #dns_rrdata_dnskey{flags = Flags,
							       protocol = 3,
							       alg = AlgNo,
							       public_key = PubKey},
				      add_keytag_to_dnskey(Key)
			      end, [ZSK_PL, KSK_PL])),
	      Expect = lists:sort([ (RR#dns_rr.data)#dns_rrdata_dnskey{}
			       || RR <- DnsKeyRR ]),
	      ?assertEqual(Expect, Generated)
	  end
	 )
       } || #dnssec_test_sample{zonename = ZoneName,
				rr_src = RRs,
				ksk_pl = KSK_PL,
				zsk_pl = ZSK_PL} <- helper_test_samples() ].

helper_test_samples() ->
    Path = "../priv/dnssec_samples.txt",
    {ok, Terms} = file:consult(Path),
    DecodeKeyProplistTuple = fun({alg, _}=Tuple) -> Tuple;
				({flags, _}=Tuple) -> Tuple;
				({name, _}=Tuple) -> Tuple;
				({Key, B64}) ->
				     Bin = base64:decode(B64),
				     Size = byte_size(Bin),
				     {Key, <<Size:32, Bin/binary>>}
			     end,
    RRCleanExclude = [nsec, nsec3, nsec3param, rrsig, dnskey],
    lists:map(
      fun({ZoneName, KeysRaw, AxfrBin}) ->
	      [ZSK, KSK] = lists:foldl(
			     fun(KeyPLRaw, Acc) ->
				     KeyPL = [ DecodeKeyProplistTuple(Tuple)
					       || {_,_} = Tuple <- KeyPLRaw ],
				     case proplists:get_value(flags, KeyPL) of
					 257 -> Acc ++ [KeyPL];
					 _ -> [KeyPL] ++ Acc 
				     end
			     end, [], KeysRaw),
	      #dns_message{answers = RR} = dns:decode_message(AxfrBin),
	      [{I, E}] = helper_uniqlist(
			   [ {D#dns_rrdata_rrsig.inception,
			      D#dns_rrdata_rrsig.expiration}
			       || #dns_rr{type = rrsig, data = D} <- RR ]),
	      NSEC3 = case [ P || #dns_rr{type=nsec3param, data=P} <- RR ] of
			  [ #dns_rrdata_nsec3param{} = Param ] -> Param;
			  [] -> undefined
		      end,
	      CleanRR = [ R || #dns_rr{type=T} = R <- RR, 
			       not lists:member(T, RRCleanExclude) ],
	      Alg = case re:run(ZoneName, "dsa") of
			{match,_} -> dsa;
			nomatch -> rsa
		    end,
	      #dnssec_test_sample{
		      zonename = ZoneName,
		      alg = Alg,
		      inception = I,
		      expiration = E,
		      nsec3 = NSEC3,
		      zsk_pl = ZSK,
		      ksk_pl = KSK,
		      rr_src = helper_uniqlist(RR),
		      rr_clean = helper_uniqlist(CleanRR)
		     }
      end, Terms
     ).

helper_verify_rrset_test_cases() ->
    lists:flatten(
      [ begin
	    Opts = [ {now, Now} ],
	    DNSKeys = [ RR || #dns_rr{type = dnskey} = RR <- RRs],
	    Dict = lists:foldl(
		     fun(#dns_rr{type = rrsig,
				 name = Name,
				 class = Class,
				 data = #dns_rrdata_rrsig{
				   type_covered = Type
				  }} = RR, Dict) ->
			   Key = {dns:dname_to_lower(Name), Class, Type},
			     dict:append(Key, RR, Dict);
			(#dns_rr{name = Name,
				 class = Class,
				 type = Type} = RR, Dict) ->
			   Key = {dns:dname_to_lower(Name), Class, Type},
			     dict:append(Key, RR, Dict)
		     end, dict:new(), RRs),
	    RRSets = [ RRSet || {_, RRSet} <- dict:to_list(Dict) ],
	    lists:map(
	      fun([#dns_rr{name=Name}|_]=TestRR) ->
		      {RRSigs, RRSet} = lists:partition(
					  fun(#dns_rr{type = Type}) ->
						  Type =:= rrsig
					  end, TestRR
					 ),
		      [#dns_rr{type = Type}|_]= RRSet,
		      TestName = helper_fmt("~s/~s", [Name, Type]),
		      [ {TestName, RRSig, RRSet, DNSKeys, Opts}
			|| RRSig <- RRSigs ]
	      end, RRSets)
	end 
      || #dnssec_test_sample{inception = Now, rr_src = RRs}
	     <- helper_test_samples() ]).

helper_samplekeypl_to_privkey(Proplist) ->
    Alg = proplists:get_value(alg, Proplist),
    helper_samplekeypl_to_privkey(Alg, Proplist).

helper_samplekeypl_to_privkey(DSA, Proplist)
  when DSA =:= dsa orelse DSA =:= nsec3dsa ->
    P = proplists:get_value(p, Proplist),
    Q = proplists:get_value(q, Proplist),
    G = proplists:get_value(g, Proplist),
    X = proplists:get_value(x, Proplist),
    [P, Q, G, X];
helper_samplekeypl_to_privkey(_RSA, Proplist) ->
    E = proplists:get_value(public_exp, Proplist),
    N = proplists:get_value(modulus, Proplist),
    D = proplists:get_value(private_exp, Proplist),
    [E, N, D].

helper_samplekeypl_to_pubkey(Proplist) ->
    Alg = proplists:get_value(alg, Proplist),
    helper_samplekeypl_to_pubkey(Alg, Proplist).

helper_samplekeypl_to_pubkey(DSA, Proplist)
  when DSA =:= dsa orelse DSA =:= nsec3dsa ->
    P = proplists:get_value(p, Proplist),
    Q = proplists:get_value(q, Proplist),
    G = proplists:get_value(g, Proplist),
    Y = proplists:get_value(y, Proplist),
    [P, Q, G, Y];
helper_samplekeypl_to_pubkey(_RSA, Proplist) ->
    E = proplists:get_value(public_exp, Proplist),
    N = proplists:get_value(modulus, Proplist),
    [ E, N].

helper_pubkey_to_dnskey_pubkey(rsa,
			       [<<ExpBinSize:32, ExpBin:ExpBinSize/binary>>,
				<<ModBinSize:32, ModBin:ModBinSize/binary>>]) ->
    case ExpBinSize > 255 of
	true -> <<0, ExpBinSize:16, ExpBin/binary, ModBin/binary>>;
 	false -> <<ExpBinSize:8, ExpBin/binary, ModBin/binary>>
    end;
helper_pubkey_to_dnskey_pubkey(dsa, [P, Q, G, Y] = Key) ->
    M = lists:max([ X || <<X:32, _:X/unit:8>> <- Key ]),
    PI = crypto:erlint(P),
    QI = crypto:erlint(Q),
    GI = crypto:erlint(G),
    YI = crypto:erlint(Y),
    M = byte_size(binary:encode_unsigned(PI)),
    T = (M - 64) div 8,
    M = 64 + T * 8,
    <<T, QI:20/unit:8, PI:M/unit:8, GI:M/unit:8, YI:M/unit:8>>.

helper_fmt(Fmt, Args) ->
    lists:flatten(io_lib:format(Fmt, Args)).

helper_uniqlist(List) ->
    lists:sort(sets:to_list(sets:from_list(List))).

-endif.



