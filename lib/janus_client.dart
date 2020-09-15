import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/webrtc.dart';
import 'package:janus_client/Plugin.dart';
import 'package:janus_client/WebRTCHandle.dart';
import 'package:janus_client/utils.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'utils.dart';

class JanusClient {
  dynamic server;
  String apiSecret;
  String token;
  bool withCredentials;
  bool _usingRest;
  String _currentJanusUri;
  Timer _keepAliveTimer;
  List<RTCIceServer> iceServers;
  int refreshInterval;
  bool _connected = false;
  int _sessionId;
  void Function(int sessionId) _onSuccess;
  void Function(dynamic) _onError;
  Uuid _uuid = Uuid();
  Map<String, dynamic> _transactions = {};
  Map<int, Plugin> _pluginHandles = {};

  dynamic get _apiMap =>
      withCredentials ? apiSecret != null ? {"apisecret": apiSecret} : {} : {};

  dynamic get _tokenMap =>
      withCredentials ? token != null ? {"token": token} : {} : {};
  IOWebSocketChannel _webSocketChannel;
  Stream<dynamic> _webSocketStream;
  WebSocketSink _webSocketSink;

  get isConnected => _connected;

  get currentJanusURI => _currentJanusUri;

  int get sessionId => _sessionId;

  /*
  * Instance of JanusClient is Starting point of any WebRTC operations with janus WebRTC gateway
  * refreshInterval is by default 50, make sure this value is less than session_timeout in janus configuration
  * value greater than session_timeout might lead to session being destroyed and can cause general functionality to fail
  *
  * */
  JanusClient(
      {@required this.server,
      @required this.iceServers,
      this.refreshInterval = 50,
      this.apiSecret,
      this.token,
      this.withCredentials = false});

  Future<dynamic> _attemptWebSocket(String url) async {
    try {
      String transaction = _uuid.v4().replaceAll('-', '');
      _currentJanusUri = url;
      _webSocketChannel = IOWebSocketChannel.connect(url,
          protocols: ['janus-protocol'], pingInterval: Duration(seconds: 2));
      _webSocketSink = _webSocketChannel.sink;
      _webSocketStream = _webSocketChannel.stream.asBroadcastStream();

      _webSocketSink.add(stringify({
        "janus": "create",
        "transaction": transaction,
        ..._apiMap,
        ..._tokenMap
      }));

      var data = parse(await _webSocketStream.first);
      if (data["janus"] == "success") {
        _sessionId = data["data"]["id"];
        _connected = true;
        _usingRest = false;
//        to keep session alive otherwise session will die after default 60 seconds.
        _keepAlive(refreshInterval: refreshInterval);
        this._onSuccess(_sessionId);
        return data;
      }
    } catch (e) {
      this._connected = false;
      _keepAliveTimer.cancel();
      debugPrint(e.toString());
      print(e.toString());
      this._onError(e);
      return Future.value(e);
    }
  }

  /*
  * private method for posting data to janus by using http client
  * */
  Future<dynamic> _postRestClient(bod, {int handleId}) async {
    var suffixUrl = '';
    if (_sessionId != null&& handleId == null) {
      suffixUrl = suffixUrl + "/$_sessionId";
    }
    else if (_sessionId != null && handleId != null) {
      suffixUrl = suffixUrl + "/$_sessionId/$handleId";
    }
    return parse(
        (await http.post(_currentJanusUri + suffixUrl, body: stringify(bod)))
            .body);
  }

  /*private method that tries to establish rest connection with janus server,
   along with setting up keepLive Timer which forces janus to keep session live unless explicitly closed by destroy()*/
  _attemptRest(String url) async {
    String transaction = _uuid.v4().replaceAll('-', '');
    var rootUrl = url;
    if (!url.endsWith("/janus")) rootUrl = url + '/janus';
    _currentJanusUri = rootUrl;
    debugPrint('should print ');
    debugPrint(rootUrl);
    debugPrint(_currentJanusUri);
    try {
      var response = await _postRestClient({
        "janus": "create",
        "transaction": transaction,
        ..._apiMap,
        ..._tokenMap
      });
      print(response);
      if (response["janus"] == "success") {
        _sessionId = response["data"]["id"];
        _connected = true;
        _usingRest = true;
//        to keep session alive otherwise session will die after default 60 seconds.
        _keepAlive(refreshInterval: refreshInterval);
        this._onSuccess(_sessionId);
        // return response;
      }

//todo:implement all http connect interface
    } catch (e) {
      // _keepAliveTimer.cancel();
      throw e;
    }
  }

  //generates sessionId and returns it as callback value in onSuccess
  connect(
      {void Function(int sessionId) onSuccess,
      void Function(dynamic) onError}) async {
    this._onSuccess = onSuccess;
    this._onError = onError;

    if (server is String) {
      debugPrint('only string');
      if (server.startsWith('ws') || server.startsWith('wss')) {
        debugPrint('trying websocket interface');
        await _attemptWebSocket(server);
      } else {
        debugPrint('trying http/https interface');
        await _attemptRest(server);
      }
    } else if (server is List<String>) {
      debugPrint('only list');
      List<String> tempServer = server;
      for (int i = 0; i < tempServer.length; i++) {
        String item = tempServer[i];
        if (item.startsWith('ws') || item.startsWith('wss')) {
          debugPrint('trying websocket interface');
          await _attemptWebSocket(item);
          if (isConnected) break;
        } else {
          debugPrint('trying http/https interface');
          debugPrint(item);
          await _attemptRest(item);
          if (isConnected) break;
        }
      }
    } else {
      debugPrint('invalid server format');
    }
  }

  destroy() {
    _keepAliveTimer.cancel();
  }

  _keepAlive({int refreshInterval}) {
    //                keep session live dude!
    if (isConnected) {
      _keepAliveTimer =
          Timer.periodic(Duration(seconds: refreshInterval), (timer) async {
        if (_usingRest) {
          debugPrint("keep live ping from rest client");
          await _postRestClient({
            "janus": "keepalive",
            "session_id": _sessionId,
            "transaction": _uuid.v4(),
            ..._apiMap,
            ..._tokenMap
          });
        } else {
          _webSocketSink.add(stringify({
            "janus": "keepalive",
            "session_id": _sessionId,
            "transaction": _uuid.v4(),
            ..._apiMap,
            ..._tokenMap
          }));
        }
      });
    }
  }
/*
*
* */
  attach(Plugin plugin) async {
    var transaction = _uuid.v4();
    Map<String, dynamic> request = {
      "janus": "attach",
      "plugin": plugin.plugin,
      "transaction": transaction
    };
    request["token"] = token;
    request["apisecret"] = apiSecret;
    request["session_id"] = sessionId;
    plugin.context = this;
    Map<String, dynamic> configuration = {
      "iceServers": iceServers.map((e) => e.toMap()).toList()
    };

    RTCPeerConnection peerConnection =
        await createPeerConnection(configuration, {});
    WebRTCHandle webRTCHandle = WebRTCHandle(
      iceServers: iceServers,
    );
    webRTCHandle.pc = peerConnection;
    plugin.webRTCHandle = webRTCHandle;
    plugin.apiSecret = apiSecret;
    plugin.sessionId = _sessionId;
    plugin.token = token;
    plugin.pluginHandles = _pluginHandles;
    plugin.transactions = _transactions;

    //WebSocket Related Code
    if (_webSocketSink != null &&
        _webSocketStream != null &&
        _webSocketChannel != null) {
      var opaqueId = plugin.opaqueId;
      if (plugin.opaqueId != null) request["opaque_id"] = opaqueId;
      _webSocketSink.add(stringify(request));
      var data = parse(await _webSocketStream.firstWhere(
          (element) => parse(element)["transaction"] == transaction));
      if (data["janus"] != "success") {
        plugin.onError(
            "Ooops: " + data["error"].code + " " + data["error"]["reason"]);
        return null;
      }
      print(data);
      int handleId = data["data"]["id"];
      debugPrint("Created handle: " + handleId.toString());

      _webSocketStream.listen((event) {
        _handleEvent(plugin, parse(event));
      });

      //attaching websocket sink and stream on plugin handle
      plugin.webSocketStream = _webSocketStream;
      plugin.webSocketSink = _webSocketSink;
      plugin.handleId = handleId;

      if (plugin.onLocalStream != null) {
        plugin.onLocalStream(peerConnection.getLocalStreams());
      }
      peerConnection.onAddStream = (MediaStream stream) {
        if (plugin.onRemoteStream != null) {
          plugin.onRemoteStream(stream);
        }
      };

//      send trickle
      peerConnection.onIceCandidate = (RTCIceCandidate candidate) {
        debugPrint('sending trickle');
        Map<dynamic, dynamic> request = {
          "janus": "trickle",
          "candidate": candidate.toMap(),
          "transaction": "sendtrickle"
        };
        request["session_id"] = plugin.sessionId;
        request["handle_id"] = plugin.handleId;
        request["apisecret"] = plugin.apiSecret;
        request["token"] = plugin.token;
        plugin.webSocketSink.add(stringify(request));
      };

      _pluginHandles[handleId] = plugin;
      debugPrint(_pluginHandles.toString());
      if (plugin.onSuccess != null) {
        plugin.onSuccess(plugin);
      }
    } else {
      //attaching plugin considering rest as fallback mechanism
      var data = await _postRestClient(request);
      if (data["janus"] != "success") {
        debugPrint("Ooops: " +
            data["error"]["code"].toString() +
            " " +
            data["error"]["reason"]);
        plugin.onError(
            "Error: " + data["error"]["code"] + " " + data["error"]["reason"]);
        return null;
      }
      int handleId = data["data"]["id"];
      plugin.handleId=handleId;
      debugPrint("Created handle: " + handleId.toString());
      _pluginHandles[handleId] = plugin;
      if (plugin.onSuccess != null) {
        plugin.onSuccess(plugin);
      }
    }
  }

  _handleEvent(Plugin plugin, Map<String, dynamic> json) {
    print('handle event called');
    print(json);

    if (json["janus"] == "keepalive") {
      // Nothing happened
      debugPrint("Got a keepalive on session " + sessionId.toString());
    } else if (json["janus"] == "ack") {
      // Just an ack, we can probably ignore
      debugPrint("Got an ack on session " + sessionId.toString());
      debugPrint(json.toString());
      var transaction = json["transaction"];
      if (transaction != null) {
        var reportSuccess = _transactions[transaction];
        if (reportSuccess != null) reportSuccess(json);
//          delete transactions[transaction];
      }
    } else if (json["janus"] == "success") {
      // Success!
      debugPrint("Got a success on session " + sessionId.toString());
      debugPrint(json.toString());
      var transaction = json["transaction"];
      if (transaction != null) {
        var reportSuccess = _transactions[transaction];
        if (reportSuccess != null) reportSuccess(json);
//          delete transactions[transaction];
      }
    } else if (json["janus"] == "trickle") {
      // We got a trickle candidate from Janus
      var sender = json["sender"];

      if (sender == null) {
        debugPrint("WMissing sender...");
        return;
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      }
      var candidate = json["candidate"];
      debugPrint("Got a trickled candidate on session " + sessionId.toString());
      debugPrint(candidate.toString());
      var config = pluginHandle.webRTCHandle;
      if (config.pc != null) {
        // Add candidate right now
        debugPrint("Adding remote candidate:" + candidate.toString());
        if (candidate.containsKey("sdpMid") &&
            candidate.containsKey("sdpMLineIndex")) {
          config.pc.addCandidate(RTCIceCandidate(candidate["candidate"],
              candidate["sdpMid"], candidate["sdpMLineIndex"]));
        }
      } else {
        // We didn't do setRemoteDescription (trickle got here before the offer?)
        debugPrint(
            "We didn't do setRemoteDescription (trickle got here before the offer?), caching candidate");
      }
    } else if (json["janus"] == "webrtcup") {
      // The PeerConnection with the server is up! Notify this
      debugPrint("Got a webrtcup event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"];
      if (sender == null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      }
      if (plugin.onWebRTCState != null) {
        plugin.onWebRTCState(true, null);
      }
    } else if (json["janus"] == "hangup") {
      // A plugin asked the core to hangup a PeerConnection on one of our handles
      debugPrint("Got a hangup event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"];
      if (sender != null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      } else {
        if (plugin.onWebRTCState != null) {
          pluginHandle.onWebRTCState(false, json["reason"]);
        }
//      pluginHandle.hangup();
        if (plugin.onDestroy != null) {
          pluginHandle.onDestroy();
        }
        _pluginHandles.remove(sender);
      }
    } else if (json["janus"] == "detached") {
      // A plugin asked the core to detach one of our handles
      debugPrint("Got a detached event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"];
      if (sender == null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        // Don't warn here because destroyHandle causes this situation.
      }
      plugin.onDetached();
      pluginHandle.detach();
    } else if (json["janus"] == "media") {
      // Media started/stopped flowing
      debugPrint("Got a media event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"];
      if (sender == null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      }
      if (plugin.onMediaState != null) {
        plugin.onMediaState(json["type"], json["receiving"]);
      }
    } else if (json["janus"] == "slowlink") {
      debugPrint("Got a slowlink event on session " + sessionId.toString());
      debugPrint(json.toString());
      // Trouble uplink or downlink
      var sender = json["sender"];
      if (sender == null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      }
      pluginHandle.slowLink(json["uplink"], json["lost"]);
    } else if (json["janus"] == "error") {
      // Oops, something wrong happened
      debugPrint("EOoops: " +
          json["error"]["code"] +
          " " +
          json["error"]["reason"]); // FIXME
      var transaction = json["transaction"];
      if (transaction) {
        var reportSuccess = _transactions[transaction];
        if (reportSuccess) {
          reportSuccess(json);
        }
      }
    } else if (json["janus"] == "event") {
      debugPrint("Got a plugin event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"];
      if (sender == null) {
        debugPrint("WMissing sender...");
        return;
      }
      var plugindata = json["plugindata"];
      if (plugindata == null) {
        debugPrint("WMissing plugindata...");
        return;
      }
      debugPrint("  -- Event is coming from " +
          sender.toString() +
          " (" +
          plugindata["plugin"].toString() +
          ")");
      var data = plugindata["data"];
//      debugPrint(data.toString());
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("WThis handle is not attached to this session");
      }
      var jsep = json["jsep"];
      if (jsep != null) {
        debugPrint("Handling SDP as well...");
        debugPrint(jsep.toString());
      }
      var callback = pluginHandle.onMessage;
      if (callback != null) {
        debugPrint("Notifying application...");
        // Send to callback specified when attaching plugin handle
        callback(data, jsep);
      } else {
        // Send to generic callback (?)
        debugPrint("No provided notification callback");
      }
    } else if (json["janus"] == "timeout") {
      debugPrint("ETimeout on session " + sessionId.toString());
      debugPrint(json.toString());
      if (_webSocketChannel != null) {
        _webSocketChannel.sink.close(3504, "Gateway timeout");
      }
    } else {
      debugPrint("WUnknown message/event  '" +
          json["janus"] +
          "' on session " +
          _sessionId.toString());
      debugPrint(json.toString());
    }
  }
}