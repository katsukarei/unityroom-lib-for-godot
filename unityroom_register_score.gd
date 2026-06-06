class_name Unityroom_scorer extends Node

@export var board_number:int = 1
@export var in_debug:bool = true
@export_enum("Always","HighScoreDesc","HighScoreAsc") var ScoreboardWriteMode:String = "Always"
var on_unityroom:bool = false
var hmac_key:String = ""
var MaxTryCount:int = 2
var Retry_IntervalSeconds:float = 6.0
var Send_IntervalSeconds:float = Retry_IntervalSeconds * (MaxTryCount + 1)
var Send_IntervalThreshold:float = Retry_IntervalSeconds * (MaxTryCount + 1)
var registered_score:float = 0.0
var internal_hold_hiscore:float = 0.0
var send_hiscore_flag:bool = false
var initial_registeration:bool = true

signal sent_hiscore_success(error_code:Error)
signal sent_hiscore_fail(error_code:Error)

### Ready
func _ready():
	if FileAccess.file_exists("res://Unityroom/hmac_unityroom.txt") and OS.get_name() == "Web":
		var file = FileAccess.open("res://Unityroom/hmac_unityroom.txt", FileAccess.READ)
		hmac_key = file.get_as_text()
		file.close()
		on_unityroom = true
		var HTTP_Requester = HTTPRequest.new()
		HTTP_Requester.set_name("HTTPRequest_Unityroom")
		add_child(HTTP_Requester)
	else:
		on_unityroom = false

### Process
func _process(_delta):
	### ハイスコア送信フラグが上がっている場合のみ送信
	if send_hiscore_flag == true:
		send_hiscore_flag = false
		var result_request = await _set_hiscore_sending(registered_score)
		# 成功シグナル発火
		if result_request["status"] == true:
			sent_hiscore_success.emit(result_request["error_code"])
		# 失敗シグナル発火
		elif result_request["status"] == false:
			sent_hiscore_fail.emit(result_request["error_code"])
		# 例外失敗シグナル発火
		else:
			sent_hiscore_fail.emit(Error.ERR_UNAVAILABLE)
	### 送信間隔計上
	if Send_IntervalSeconds <= 100.0 and send_hiscore_flag == false:
		Send_IntervalSeconds += _delta

### ハイスコアセット実行
func _set_hiscore_sending(_score:float):
	if on_unityroom == false:
		_write_debug_log("スコア送信 BoardNo=" + str(board_number) + " Score=" + str(_score) + " (unityroomにゲームをアップロードすると実際に送信されます)")
		return {"status": false, "error_code": Error.ERR_UNAVAILABLE}
	if ! _judge_hiscore(_score):
		_write_debug_log("ハイスコア未更新のため送信しません BoardNo=" + str(board_number) + " Score=" + str(_score))
		return {"status": true, "error_code": Error.ERR_SKIP}
	var trycount:int = 0
	var send_success:bool = false
	var result_request
	while trycount < MaxTryCount and send_success == false:
		var retry_count:String = ""
		if trycount != 0:
			retry_count = "(リトライ "+ str(trycount) + "回目)"
		_write_debug_log("スコア送信開始 BoardNo=" + str(board_number) + " Score=" + str(_score) + " " + retry_count)
		result_request = await _request_unityroom_api(_score)
		trycount += 1
		if result_request["status"] == false:
			_write_debug_log("スコア送信失敗 BoardNo=" + str(board_number) + " Score=" + str(_score) + " Data=" + 	str(result_request["error_code"]) + " リトライ残=" + str(MaxTryCount - trycount) )
			await get_tree().create_timer(Retry_IntervalSeconds).timeout
		else:
			_write_debug_log("スコア送信成功 BoardNo=" + str(board_number) + " Score=" + str(_score) + " Data=" + 	str(result_request["error_code"]) )
			send_success = true
	return result_request

### ハイスコア値セット
func set_hiscore_value(_score:float):
	registered_score = _score

### ハイスコア登録フラグUP(リトライ間隔 * リトライ回数+1 以内で拒否)
func set_send_hiscore() -> bool:
	if Send_IntervalSeconds < Send_IntervalThreshold:
		return false
	else:
		send_hiscore_flag = true
		Send_IntervalSeconds = 0.0
		return true

### UnityroomAPI呼び出し
func _request_unityroom_api(_score:float):
	var path = "/gameplay_api/v1/scoreboards/" + str(board_number) + "/scores"
	var unixTime = str(Time.get_unix_time_from_system())
	var scoreText = str(_score)
	var hmacDataText = "POST\n" + path + "\n" + unixTime + "\n" + scoreText
	var hmac = get_hmac_sha256(hmacDataText, hmac_key)
	# AddField() は内部で key=value&key2=value2の形になる
	var send_data = "score=" + scoreText
	var headers = ["X-Unityroom-Signature:" + hmac , "X-Unityroom-Timestamp:" + unixTime]
	var hostname = JavaScriptBridge.eval("window.location.hostname")
	var request_result = await get_node("HTTPRequest_Unityroom").request("https://" + hostname + path, headers, HTTPClient.METHOD_POST, send_data)
	if request_result != Error.OK:
		return { "status": false, "error_code": request_result }
	else:
		return { "status": true, "error_code": request_result }

### HMAC計算
func get_hmac_sha256(dataText:String, base64AutehticationKey:String):
	var dataBytes: PackedByteArray = dataText.to_utf8_buffer()
	var keyBytes: PackedByteArray = Marshalls.base64_to_raw(base64AutehticationKey)
	var hmac_instance = Crypto.new()
	var hmacBytes = hmac_instance.hmac_digest(HashingContext.HASH_SHA256,keyBytes,dataBytes)
	var hmacText = hmacBytes.hex_encode()
	return hmacText

### Unityroom上か否かを返却(返却値: bool)
func is_on_unityroom() -> bool:
	return on_unityroom

### 登録間隔許容状態かを返却
func is_Ready_Upload() -> bool:
	if Send_IntervalSeconds < Send_IntervalThreshold:
		return false
	else:
		return true

### Debugログ出力
func _write_debug_log(_log:String):
	if in_debug == true:
		var debug_log = "[debug][unityroom]" + _log
		print(debug_log)
	return

### 登録スコアがハイスコアか否かを判断(同一セッション上のみ)
func _judge_hiscore(_score:float) -> bool:
	if initial_registeration == true or ScoreboardWriteMode == "Always":
		internal_hold_hiscore = _score
		initial_registeration = false
		return true
	else:
		if ScoreboardWriteMode == "HighScoreDesc" and _score > internal_hold_hiscore:
			internal_hold_hiscore = _score
			return true
		elif ScoreboardWriteMode == "HighScoreAsc" and _score < internal_hold_hiscore:
			internal_hold_hiscore = _score
			return true
		else:
			return false
