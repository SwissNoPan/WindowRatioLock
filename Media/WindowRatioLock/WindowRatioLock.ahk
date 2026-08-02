#Requires AutoHotkey v2.0
#SingleInstance Force


; ==========================================================
; DPI AWARENESS
; ==========================================================

try
{
    DllCall("SetThreadDpiAwarenessContext", "ptr", -4)
}
catch
{
    ; DPI-Anpassung nicht verfügbar
}


; ==========================================================
; ADMINISTRATORRECHTE
; ==========================================================

if !A_IsAdmin
{
    Loop
    {
        try
        {
            Run '*RunAs "' A_ScriptFullPath '"'
            ExitApp()
        }
        catch
        {
            result := MsgBox(
			Lang("AdminRightsRequired"),
			Lang("AppName"),
			"RetryCancel Icon!"
		)
		if (result = "Retry")
			continue
		ExitApp()
        }
    }
}

; ==========================================================
; KONSTANTEN
; ==========================================================

EVENT_SYSTEM_MOVESIZESTART := 0x000A
EVENT_SYSTEM_MOVESIZEEND   := 0x000B

EVENT_OBJECT_CREATE := 0x8000
EVENT_OBJECT_SHOW   := 0x8002

RATIO_TOLERANCE := 0.02
MAX_CACHE_SIZE := 200
SELECTION_COLOR := "0078D7"
NORMAL_COLOR := "202020"

CHILD_MIN_WIDTH_RATIO := 0.70
CHILD_MIN_HEIGHT_RATIO := 0.70


; ==========================================================
; GLOBALE VARIABLEN
; ==========================================================

global ConfigFile := A_ScriptDir "\Settings.ini"
global IconFile := A_ScriptDir "\monitor.ico"
global PauseIconFile := A_ScriptDir "\monitor_pause.ico"
global LanguageFile := A_ScriptDir "\Languages.ini"
global CurrentLanguage := "DE"

global Programs := Map()
global ListRowToProgram := Map()
global CheckedStartupWindows := Map()

global hookStart := 0
global hookEnd := 0
global hookShow := 0
global callback := 0

global StatusGui := 0
global SettingsGui := 0
global SettingsListView := 0
global ProgramImageList := 0
global DefaultIconIndex := 0

global ratioWEdit := 0
global ratioHEdit := 0
global LanguageDropdown := 0
global LangCache := Map()

global areaWindowButton := 0
global areaClientButton := 0
global selectedArea := "WINDOW"

global positionTopLeftButton := 0
global positionCenterButton := 0
global selectedPosition := "TOPLEFT"

; Button-Zustände werden später direkt über die Buttons gezeichnet

global paused := false
global correcting := false
global verifying := false
global resizing := false

global startW := 0
global startH := 0
global startWindowW := 0
global startWindowH := 0
global ResizeStart := Map()

global ChildCache := Map()
global ChildFailCount := Map()
global ClientFailCount := Map()
global LearnedChildClass := Map()
global ProcessCache := Map()
global StartupWindows := Map()
global LearnedOffsets := Map()
global PendingCalibration := Map()
global ScriptPID := DllCall("GetCurrentProcessId")

global SelectingWindow := false
global SelectedClickHwnd := 0
global analyzing := false

global CurrentProgram := ""
global SettingsDirty := false
global SettingsNeedSave := false
global SaveButton := 0
global RemoveButton := 0

global areaWindowButton := 0
global areaClientButton := 0
global IgnoreControlEvents := false
global OriginalSettings := Map()
global SelectionGui := 0
global SelectionFrames := Map()
global HoverButton := 0

; ==========================================================
; CLASS: ChildFinder
; ==========================================================
; Kapselt die Logik zum Finden des größten Child-Fensters
; und ersetzt die problematischen globalen Variablen.


class ChildFinder
{
    static GetFirstChild(hwnd)
    {
        return DllCall("GetWindow", "Ptr", hwnd, "UInt", 5, "Ptr")
    }
    static GetNextChild(hwnd)
    {
        return DllCall("GetWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    }
	
	static AnalyzeChildren(hwnd)
	{
		childCount := 0
		childArea := 0

		child := ChildFinder.GetFirstChild(hwnd)

		while child
		{
			if DllCall("IsWindowVisible", "Ptr", child)
			{
				try
				{
					WinGetPos(&x, &y, &w, &h, "ahk_id " child)

					if (w > 0 && h > 0)
					{
						childCount++
						childArea += w * h
					}
				}
			}

			child := ChildFinder.GetNextChild(child)
		}

		return {
			Count: childCount,
			Area: childArea
		}
	}
		
	static CollectChildren(parentHwnd, program, parentW, parentH, &candidates, depth := 1)
	{
		child := ChildFinder.GetFirstChild(parentHwnd)

		while child
		{
			if DllCall("IsWindowVisible", "Ptr", child)
			{
				try
				{
					WinGetPos(&x, &y, &w, &h, "ahk_id " child)

					if (w >= 20 && h >= 20)
					{
						widthRatio := w / parentW
						heightRatio := h / parentH

						if (widthRatio >= CHILD_MIN_WIDTH_RATIO
							&& heightRatio >= CHILD_MIN_HEIGHT_RATIO)
						{
							class := ""

							try
								class := WinGetClass("ahk_id " child)
							if ChildFinder.IsIgnoredClass(class)
							{
								ChildFinder.CollectChildren(
									child,
									program,
									parentW,
									parentH,
									&candidates,
									depth + 1
								)

								child := ChildFinder.GetNextChild(child)
								continue
							}
							analysis := ChildFinder.AnalyzeChildren(child)
							candidates.Push({
								Hwnd: child,
								Class: class,
								Depth: depth,

								Preferred: HasProp(program, "PreferredClass")
									&& StrLower(program.PreferredClass)=StrLower(class),

								X: x,
								Y: y,
								Width: w,
								Height: h,

								ChildCount: analysis.Count,
								ChildArea: analysis.Area
							})
						}
					}
				}

				ChildFinder.CollectChildren(
					child,
					program,
					parentW,
					parentH,
					&candidates,
					depth + 1
				)
			}

			child := ChildFinder.GetNextChild(child)
		}
	}
	
	static GetCandidates(parentHwnd, program)
	{
    candidates := []

    try
        GetClientRectEx(
			parentHwnd,
			&dummyX,
			&dummyY,
			&parentW,
			&parentH
		)
    catch
	
        return candidates

		ChildFinder.CollectChildren(
			parentHwnd,
			program,
			parentW,
			parentH,
			&candidates
		)

    return candidates
	}
	
	static IsMostlyInside(inner, outer)
	{
		if (inner.Hwnd = outer.Hwnd)
			return false

		if (inner.X < outer.X)
			return false

		if (inner.Y < outer.Y)
			return false

		if (inner.X + inner.Width > outer.X + outer.Width)
			return false

		if (inner.Y + inner.Height > outer.Y + outer.Height)
			return false

		return true
	}
	
	static IsIgnoredClass(class)
	{
		switch StrLower(class)
		{
			case "button":
			case "static":
			case "scrollbar":
			case "toolbarwindow32":
			case "rebarwindow32":
			case "msctls_statusbar32":
			case "sysheader32":
			case "combobox":
			case "edit":
			case "listbox":
			case "richedit":
			case "richedit20w":
				return true
		}

		return false
	}
	
	static CalculateScore(parentW, parentH, candidate)
	{
		score := 0

		; -------------------------
		; Flächenanteil
		; -------------------------

		parentArea := parentW * parentH

		if (parentArea > 0)
		{
			area := candidate.Width * candidate.Height
			score += Round((area / parentArea) * 1000)
		}

		; -------------------------
		; Mittelpunkt
		; -------------------------

		parentCenterX := parentW / 2
		parentCenterY := parentH / 2

		centerX := candidate.X + candidate.Width / 2
		centerY := candidate.Y + candidate.Height / 2

		score -= Round(Abs(centerX - parentCenterX) / 8)
		score -= Round(Abs(centerY - parentCenterY) / 8)

		; -------------------------
		; Fast so groß wie Parent?
		; -------------------------

		if (candidate.Width >= parentW * 0.95)
			score += 200

		if (candidate.Height >= parentH * 0.95)
			score += 200

		; -------------------------
		; Seitenverhältnis ähnlich?
		; -------------------------

		parentRatio := parentW / parentH
		childRatio := candidate.Width / candidate.Height

		diff := Abs(parentRatio - childRatio)

		score += Max(0, 150 - Round(diff * 300))

		; -------------------------
		; Sehr schmale Controls bestrafen
		; -------------------------

		if (candidate.Width < parentW * 0.40)
			score -= 300

		if (candidate.Height < parentH * 0.40)
			score -= 300
			
		; -------------------------
		; Bereits gelernte Klasse bevorzugen
		; -------------------------
		if (candidate.Preferred)
			score += 5000

		; -------------------------
		; Klassenbonus
		; -------------------------

		switch StrLower(candidate.Class)
		{
			case "chrome_renderwidgethosthwnd":
				score += 800

			case "chrome_widgetwin_0":
			case "chrome_widgetwin_1":
				score += 300

			case "mediatek":
				score += 400

			case "qt5qwindowicon":
			case "qt6qwindowicon":
				score += 300

			case "unitycontainerwndclass":
				score += 600

			case "sdl_app":
				score += 500
		}
		
				; -------------------------
				; Overlay-Erkennung
				; -------------------------

				if (candidate.Y > parentH * 0.70
					&& candidate.Height < parentH * 0.35)
					score -= 500

				if (candidate.Y = 0
					&& candidate.Height < parentH * 0.25)
					score -= 400

				if (candidate.X > parentW * 0.70
					&& candidate.Width < parentW * 0.30)
					score -= 400

				if (candidate.X = 0
					&& candidate.Width < parentW * 0.30)
					score -= 400
		
				; -------------------------
				; Tiefe im Fensterbaum
				; -------------------------

				if (candidate.Depth = 2)
					score += 75
				else if (candidate.Depth = 3)
					score += 150
				else if (candidate.Depth >= 4)
					score += 100
				
				; -------------------------
				; Enthält andere Fenster?
				; -------------------------

				score += candidate.ContainsCount * 40

				; -------------------------
				; Liegt komplett in anderen?
				; -------------------------

				score -= candidate.InsideCount * 60
				
				; -------------------------
				; Enthält viele Unterfenster?
				; -------------------------

				if (candidate.ChildCount > 0)
					score += Min(candidate.ChildCount * 10, 80)

				; -------------------------
				; Anteil der Fläche, die von Kindern belegt wird
				; -------------------------

				area := candidate.Width * candidate.Height

				if (area > 0)
				{
					coverage := candidate.ChildArea / area

					; Werte über 1 entstehen durch überlappende Kinder
					coverage := Min(coverage, 1.0)

					; Ein leichter Bonus für Container,
					; aber nicht so stark, dass Renderfenster verlieren.
					score += Round(coverage * 80)
				}
				
		return score
	}
	
}

class ProgramAnalyzer
{
    static CurrentVersion := 1

    static Check(program)
    {
        global Programs

        if !Programs.Has(program)
            return

        data := Programs[program]

        ; Nur CLIENT benötigt eine Analyse
        if (data.Area != "CLIENT")
            return

        ; Bereits aktuell analysiert?
        if (HasProp(data, "AnalysisVersion")
            && data.AnalysisVersion >= ProgramAnalyzer.CurrentVersion)
        {
            return
        }

        ProgramAnalyzer.Start(program)
    }

	static Start(program)
	{
		global analyzing, Programs

		analyzing := true

		hwnd := WinExist("ahk_exe " program)

		if !hwnd
		{
			analyzing := false
			return
		}

		data := Programs[program]

		viewport := ViewportResolver.Resolve(
			hwnd,
			program,
			data
		)

		if !viewport
		{
			analyzing := false
			return
		}

		targetHwnd := viewport.Hwnd

		viewportData := ProgramAnalyzer.MeasureViewport(targetHwnd)
		children := ProgramAnalyzer.AnalyzeChildWindows(targetHwnd)


		; ==================================================
		; NEUE ANALYSE KOMMT HIER HIN
		; Aktuell nur Struktur testen
		; ==================================================


		;MsgBox(
		;	"Analyse gestartet:`n`n"
		;	program
		;	"`nHWND: " hwnd
		;	"`nAnalyse Fenster: " targetHwnd
		;	"`nFenster HWND: " hwnd
		;	"`nViewport: "
		;	viewportData.Width "x" viewportData.Height
		;	"`n`nGefundene Childs: " children.Length
		;)

		;for child in children
		;{
		;	MsgBox(
		;		"Child HWND: " child.Hwnd
		;		"`nClass: " child.Class
		;		"`nGröße: " child.Width "x" child.Height
		;		"`nPosition: " child.X "," child.Y
		;	)
		;}


		; Analyse abgeschlossen
		Programs[program].AnalysisPending := false
		Programs[program].AnalysisVersion := ProgramAnalyzer.CurrentVersion

		analyzing := false
	}
	
	static MeasureViewport(hwnd)
	{
		data := {}

		x := 0
		y := 0
		w := 0
		h := 0

		GetClientRectEx(
			hwnd,
			&x,
			&y,
			&w,
			&h
		)

		data.X := x
		data.Y := y
		data.Width := w
		data.Height := h

		return data
	}
	
	static AnalyzeChildWindows(hwnd)
	{
		result := []

		try
		{
			children := WinGetList("ahk_parent " hwnd)

			for childHwnd in children
			{
				try
				{
					class := WinGetClass("ahk_id " childHwnd)

					WinGetPos(
						&x,
						&y,
						&w,
						&h,
						"ahk_id " childHwnd
					)

					result.Push({
						Hwnd: childHwnd,
						Class: class,
						X: x,
						Y: y,
						Width: w,
						Height: h
					})
				}
			}
		}

		return result
	}
	
}

; ==========================================================
; CLASS: ViewportResolver
; ==========================================================

class ViewportResolver
{	
	
	static CreateViewport(parentHwnd)
	{
		return {
			Hwnd: parentHwnd,

			Source: "PARENT",
			Strategy: "",

			X: 0,
			Y: 0,
			Width: 0,
			Height: 0,

			OffsetTop: 0,
			OffsetBottom: 0,
			OffsetLeft: 0,
			OffsetRight: 0,

			Confidence: 0,
			Valid: false,
			Class: "",
			Diagnostics: Map()
		}
	}
	
	static CloneViewport(viewport)
	{
		copy := {}

		for key, value in viewport.OwnProps()
		{
			if IsObject(value)
				copy.%key% := value.Clone()
			else
				copy.%key% := value
		}

		return copy
	}
	
	static GetCacheEntry(parentHwnd)
	{
		global ChildCache
		if !ChildCache.Has(parentHwnd)
			return false
		return ChildCache[parentHwnd]
	}
	
	static RemoveCacheEntry(parentHwnd)
		{
			global ChildCache
			if ChildCache.Has(parentHwnd)
				ChildCache.Delete(parentHwnd)
		}
	
    static Resolve(parentHwnd, process, program)
    {

        result := ViewportResolver.CreateViewport(parentHwnd)
		GetClientRectEx(
			parentHwnd,
			&parentX,
			&parentY,
			&parentW,
			&parentH
		)

		if (program.Area != "CLIENT")
		return ViewportResolver.ResolveWindow(result)
		
		return ViewportResolver.ResolveClient(
			parentHwnd,
			process,
			program,
			parentW,
			parentH,
			result
		)
		
	}

	static ResolveWindow(result)
	{
		result.Source := "WINDOW"
		result.Strategy := "Window"
		result.Confidence := 100
		return ViewportResolver.Measure(result)
	}
	
	static ResolveClient(parentHwnd, process, program, parentW, parentH, result)
	{
		offsets := ViewportResolver.GetOffsets(program)
		result.OffsetTop := offsets.Top
		result.OffsetBottom := offsets.Bottom
		result.OffsetLeft := offsets.Left
		result.OffsetRight := offsets.Right
		return ViewportResolver.ResolveViewport(
			parentHwnd,
			process,
			program,
			parentW,
			parentH,
			result
		)
	}
	
	static TryStrategies(parentHwnd, process, program, parentW, parentH, result)
	{
		viewport := ViewportResolver.TryCachedViewport(
			parentHwnd,
			process,
			program,
			parentW,
			parentH,
			result
		)

		if IsObject(viewport)
			return viewport

		viewport := ViewportResolver.TryPreferredClass(
			parentHwnd,
			process,
			program,
			parentW,
			parentH,
			result
		)

		if IsObject(viewport)
			return viewport

		viewport := ViewportResolver.FindBestViewport(
			parentHwnd,
			process,
			program,
			parentW,
			parentH,
			result
		)

		if IsObject(viewport)
			return viewport

		return false
	}
	
	static ResolveViewport(parentHwnd, process, program, parentW, parentH, result)
	{
	
		viewport := ViewportResolver.TryStrategies(
			parentHwnd,
			process,
			program,
			parentW,
			parentH,
			result
		)

		if IsObject(viewport)
			return viewport

		return ViewportResolver.ResolveParentViewport(result)
	}
	
	static Measure(viewport)
	{
		x := 0
		y := 0
		w := 0
		h := 0
		GetClientRectEx(
			viewport.Hwnd,
			&x,
			&y,
			&w,
			&h
		)
		viewport.X := x
		viewport.Y := y
		viewport.Width := w
		viewport.Height := h

		viewport := ViewportResolver.ApplyOffsets(viewport)
		viewport.Valid := (viewport.Width > 0 && viewport.Height > 0)

		return viewport
	}
	
	static ApplyOffsets(viewport)
	{
		viewport.X += viewport.OffsetLeft
		viewport.Y += viewport.OffsetTop
		viewport.Width -= viewport.OffsetLeft
		viewport.Width -= viewport.OffsetRight
		viewport.Height -= viewport.OffsetTop
		viewport.Height -= viewport.OffsetBottom
		viewport.Width := Max(0, viewport.Width)
		viewport.Height := Max(0, viewport.Height)
		return viewport
	}
	
	static GetOffsets(program)
	{
		return {
			Top: HasProp(program, "OffsetTop") ? program.OffsetTop : 0,
			Bottom: HasProp(program, "OffsetBottom") ? program.OffsetBottom : 0,
			Left: HasProp(program, "OffsetLeft") ? program.OffsetLeft : 0,
			Right: HasProp(program, "OffsetRight") ? program.OffsetRight : 0
		}
	}

    static IsSameViewport(old, current)
    {
        if (old.Class != current.Class)
            return false

        if (Abs(old.Width - current.Width) > 4)
            return false

        if (Abs(old.Height - current.Height) > 4)
            return false

        if (Abs(old.X - current.X) > 4)
            return false

        if (Abs(old.Y - current.Y) > 4)
            return false

        return true
    }

	static TryCachedViewport(parentHwnd, process, program, parentW, parentH, result)
	{
		cached := ViewportResolver.GetCacheEntry(parentHwnd)
		if !IsObject(cached)
			return false
		if !DllCall("IsWindow", "Ptr", cached.Hwnd)
		{
			ViewportResolver.RemoveCacheEntry(parentHwnd)
			return false
		}

		current := {
			Hwnd: cached.Hwnd,
			Class: cached.Class
		}

		x := 0
		y := 0
		w := 0
		h := 0
		GetClientRectEx(
			cached.Hwnd,
			&x,
			&y,
			&w,
			&h
		)
		current.X := x
		current.Y := y
		current.Width := w
		current.Height := h

		if !ViewportResolver.IsSameViewport(cached, current)
		{
			ViewportResolver.RemoveCacheEntry(parentHwnd)
			return false
		}
		cached.OffsetTop := result.OffsetTop
		cached.OffsetBottom := result.OffsetBottom
		cached.OffsetLeft := result.OffsetLeft
		cached.OffsetRight := result.OffsetRight

		return ViewportResolver.CloneViewport(cached)
	}
	
	static TryPreferredClass(parentHwnd, process, program, parentW, parentH, result)
	{
		if !HasProp(program, "PreferredClass")
			return false

		preferredClass := program.PreferredClass

		if (preferredClass = "")
			return false

		candidates := ChildFinder.GetCandidates(parentHwnd, program)

		for candidate in candidates
		{
			if (candidate.Class != preferredClass)
				continue

			candidate := ViewportResolver.MeasureCandidate(candidate)

			candidate.Strategy := "PreferredClass"
			candidate.Confidence := 95

			return ViewportResolver.AcceptCandidate(
				parentHwnd,
				process,
				candidate,
				result
			)
		}

		return false
	}
	
	static AcceptCandidate(parentHwnd, process, candidate, result)
	{
		viewport := ViewportResolver.BuildViewportFromCandidate(
			result,
			candidate
		)

		ViewportResolver.CacheViewport(
			parentHwnd,
			process,
			viewport
		)

		return viewport
	}
	
	static ResolveParentViewport(result)
	{
		result.Source := "PARENT"
		result.Strategy := "ParentClient"
		result.Confidence := 60
		return ViewportResolver.Measure(result)
	}
	
	static CalculatePreferredClassBonus(candidate, preferredClass)
	{
		if (preferredClass = "")
			return 0

		if (candidate.Class != preferredClass)
			return 0

		return 1000
	}
	
	static CalculateCandidateScore(parentW, parentH, candidate, preferredClass)
	{
		score := ChildFinder.CalculateScore(
			parentW,
			parentH,
			candidate
		)

		score += ViewportResolver.CalculatePreferredClassBonus(
			candidate,
			preferredClass
		)

		return score
	}
	
	static EvaluateCandidates(candidates, parentW, parentH, preferredClass)
	{
		for candidate in candidates
		{
			candidate.ContainsCount := 0
			candidate.InsideCount := 0
		}

		for outer in candidates
		{
			for inner in candidates
			{
				if ChildFinder.IsMostlyInside(inner, outer)
				{
					outer.ContainsCount++
					inner.InsideCount++
				}
			}
		}

		for candidate in candidates
		{
			candidate.Score := ViewportResolver.CalculateCandidateScore(
				parentW,
				parentH,
				candidate,
				preferredClass
			)
		}

		return candidates
	}
	
	static SelectHighestScore(candidates)
	{
		best := 0
		bestScore := -1

		for candidate in candidates
		{
			if (candidate.Score > bestScore)
			{
				bestScore := candidate.Score
				best := candidate
			}
		}

		return best
	}
	
	static SelectBestCandidate(candidates, program, parentW, parentH)
	{

		preferredClass := ""

		if HasProp(program, "PreferredClass")
			preferredClass := program.PreferredClass

		candidates := ViewportResolver.EvaluateCandidates(
			candidates,
			parentW,
			parentH,
			preferredClass
		)

		return ViewportResolver.SelectHighestScore(candidates)
	}
	
	static MeasureCandidateGeometry(candidate)
	{
		x := 0
		y := 0
		w := 0
		h := 0
		GetClientRectEx(
			candidate.Hwnd,
			&x,
			&y,
			&w,
			&h
		)
		return {
			X: x,
			Y: y,
			Width: w,
			Height: h
		}
	}
		
	static BuildViewportFromCandidate(result, candidate)
	{
		result.Hwnd := candidate.Hwnd
		result.Class := candidate.Class

		result.Source := "CHILD"
		result.Strategy := candidate.Strategy
		result.Confidence := candidate.Confidence

		result.X := candidate.X
		result.Y := candidate.Y
		result.Width := candidate.Width
		result.Height := candidate.Height

		result.Valid := (result.Width > 0 && result.Height > 0)

		return ViewportResolver.ApplyOffsets(result)
	}
	
	static MeasureCandidate(candidate)
	{
		measurement := ViewportResolver.MeasureCandidateGeometry(candidate)

		candidate := ViewportResolver.CreateCandidate(candidate)

		candidate.X := measurement.X
		candidate.Y := measurement.Y
		candidate.Width := measurement.Width
		candidate.Height := measurement.Height

		return candidate
	}
	
	static FindCandidates(parentHwnd, program)
	{
		return ChildFinder.GetCandidates(
			parentHwnd,
			program
		)
	}
	
	static CreateCandidate(candidate)
	{
		return {
			Hwnd: candidate.Hwnd,
			Class: candidate.Class,

			X: candidate.X,
			Y: candidate.Y,
			Width: candidate.Width,
			Height: candidate.Height,

			Depth: candidate.Depth,

			ChildCount: candidate.ChildCount,
			ChildArea: candidate.ChildArea,

			ContainsCount: HasProp(candidate, "ContainsCount") ? candidate.ContainsCount : 0,
			InsideCount: HasProp(candidate, "InsideCount") ? candidate.InsideCount : 0,

			Score: HasProp(candidate, "Score") ? candidate.Score : 0,

			Strategy: "BestChild",
			Confidence: 90,
			Diagnostics: Map()
		}
	}
	
	static CacheViewport(parentHwnd, process, viewport)
	{
		global ChildCache

		ChildCache[parentHwnd] := ViewportResolver.CloneViewport(viewport)

		if (viewport.Class != "")
			RememberPreferredClass(process, viewport.Class)
	}
	
	static FindBestViewport(parentHwnd, process, program, parentW, parentH, result)
	{
		candidate := ViewportResolver.DetectBestCandidate(
			parentHwnd,
			program,
			parentW,
			parentH
		)

		if !IsObject(candidate)
			return false

		candidate := ViewportResolver.MeasureCandidate(candidate)

		return ViewportResolver.AcceptCandidate(
			parentHwnd,
			process,
			candidate,
			result
		)
	}
	
	static DetectBestCandidate(parentHwnd, program, parentW, parentH)
	{
		candidates := ViewportResolver.FindCandidates(
			parentHwnd,
			program
		)

		candidate := ViewportResolver.SelectBestCandidate(
			candidates,
			program,
			parentW,
			parentH
		)

		return candidate
	}
	
	static HandleClientFailure(hwnd, process)
	{
		global ClientFailCount
		count := 0
		if ClientFailCount.Has(process)
			count := ClientFailCount[process]
		count++
		ClientFailCount[process] := count
		if (count > 1)
			return
		FixRatio(hwnd, process)
	}
	
	static ResetClientFailures(process)
	{
		global ClientFailCount
		if ClientFailCount.Has(process)
			ClientFailCount.Delete(process)
	}
	
}

; ==========================================================
; CLASS: CacheManager
; ==========================================================
; Begrenzt die Größe von Caches, um Memory-Leaks zu vermeiden

class CacheManager
{
    static Set(map, key, value)
    {
        if (map.Count >= MAX_CACHE_SIZE)
        {
            ; Einfache Strategie: Map leeren und neu aufbauen
            ; (Map ist nicht geordnet, daher keine LRU möglich)
            map.Clear()
        }
        map[key] := value
    }
    static Get(map, key)
    {
        return map.Has(key) ? map[key] : ""
    }
}


; ==========================================================
; START
; ==========================================================

Persistent

A_IconTip := "WindowRatioLock"

OnMessage(0x404, TrayClick)

LoadSettings()
LoadLanguage()
CreateStatusGui()
CreateTrayMenu()

SetTimer(UpdateTrayIcon, -50)
StartupWindows.Clear()
CheckedStartupWindows.Clear()

SetTimer(CheckStartupWindows, -1000)

UpdateTrayIcon()


; ==========================================================
; TRAY ICON
; ==========================================================

UpdateTrayIcon()
{
    global paused, IconFile, PauseIconFile
    if (paused && FileExist(PauseIconFile))
    {
        TraySetIcon(PauseIconFile)
        return
    }
    if FileExist(IconFile)
        TraySetIcon(IconFile)
}


; ==========================================================
; ICONS
; ==========================================================

GetProgramIcon(data)
{
    try
    {
        if !data.HasOwnProp("Path") || (data.Path = "")
            return ""
        if FileExist(data.Path)
            return data.Path
    }
    catch
    {
    }
    return ""
}


DisplayProgramName(name)
{
    SplitPath(name, , , , &nameNoExt)
    if (nameNoExt = "")
        return ""
    return StrUpper(SubStr(nameNoExt, 1, 1)) . SubStr(nameNoExt, 2)
}


; ==========================================================
; STATUS GUI
; ==========================================================

CreateStatusGui()
{
    global StatusGui
    if IsObject(StatusGui)
        return
    StatusGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x40000", "WindowRatioLock")
    StatusGui.BackColor := "202020"
    statusText := StatusGui.AddText("cFFFFFF w300 h50 Center", "")
    statusText.SetFont("s12 bold", "Segoe UI")
    ; Speichere Referenz im Gui-Objekt für späteren Zugriff
    StatusGui.StatusText := statusText
}


ShowStatus(text)
{
    global StatusGui
    if !IsObject(StatusGui)
        CreateStatusGui()
    StatusGui.StatusText.Text := text
    StatusGui.Show("NoActivate AutoSize Center")
    ; Sicherstellen, dass es wirklich ganz oben bleibt
    WinSetAlwaysOnTop(true, "ahk_id " StatusGui.Hwnd)
    SetTimer(HideStatusGui, -1500)
}


HideStatusGui()
{
    global StatusGui
    try
        StatusGui.Hide()
}


ClearStatus()
{
    global StatusGui
    if IsObject(StatusGui) && IsObject(StatusGui.StatusText)
        StatusGui.StatusText.Text := "Bereit"
}


; ==========================================================
; TRAY MENU
; ==========================================================

CreateTrayMenu()
{
    A_TrayMenu.Delete()

    A_TrayMenu.Add()
    A_TrayMenu.Add(Lang("TrayOpenSettings"), OpenSettings)
    A_TrayMenu.Add(Lang("TrayAddProgram"), AddCurrentWindow)

    A_TrayMenu.Add()

    A_TrayMenu.Add(Lang("TrayPause"), TogglePause)
    if paused
        A_TrayMenu.Rename(Lang("TrayPause"), Lang("TrayResume"))

    A_TrayMenu.Add()

    if StartupEnabled()
        A_TrayMenu.Add(Lang("TrayDisableStartup"), DisableStartup)
    else
        A_TrayMenu.Add(Lang("TrayEnableStartup"), EnableStartup)

    A_TrayMenu.Add()
    A_TrayMenu.Add(Lang("TrayExit"), ExitScript)
}

; ==========================================================
; SPRACH SYSTEM
; ==========================================================

LoadLanguage()
{
    global ConfigFile, CurrentLanguage

    CurrentLanguage := IniRead(
        ConfigFile,
        "General",
        "Language",
        "DE"
    )

    if (
		CurrentLanguage != "DE"
		&& CurrentLanguage != "EN"
		&& CurrentLanguage != "FR"
		&& CurrentLanguage != "ES"
		&& CurrentLanguage != "IT"
		&& CurrentLanguage != "NL"
		&& CurrentLanguage != "PL"
		&& CurrentLanguage != "PT-BR"
		&& CurrentLanguage != "TR"
		&& CurrentLanguage != "RU"
		&& CurrentLanguage != "JA"
		&& CurrentLanguage != "KO"
		&& CurrentLanguage != "ZH-CN"
		&& CurrentLanguage != "CS"
		&& CurrentLanguage != "SV"
		&& CurrentLanguage != "UK"
		&& CurrentLanguage != "HU"
		&& CurrentLanguage != "RO"
		&& CurrentLanguage != "EL"
		&& CurrentLanguage != "DA"
		&& CurrentLanguage != "FI"
		&& CurrentLanguage != "NO"
	)
	{
		CurrentLanguage := "DE"
	}
}

Lang(key)
{
    global LanguageFile, CurrentLanguage

    if LangCache.Has(CurrentLanguage "|" key)
		return LangCache[CurrentLanguage "|" key]

    text := FileRead(
        LanguageFile,
        "UTF-8"
    )

    section := false

    for line in StrSplit(text, "`n")
    {
        line := Trim(line, " `t`r`n" Chr(0xFEFF))

        if (line = "[" CurrentLanguage "]")
        {
            section := true
            continue
        }

        if section
        {
            if RegExMatch(line, "^\[(.*)\]$")
                break

            if InStr(line, key "=")
			{
				parts := StrSplit(line, "=", 2)

				if (parts.Length = 2 && parts[1] = key)
				{
					value := parts[2]
					LangCache[CurrentLanguage "|" key] := value
					return value
				}
			}
        }
    }

    return key
}

LangClearCache()
{
    global LangCache

    LangCache.Clear()
}

SetLanguage(language)
{
    global ConfigFile, CurrentLanguage

    if (
		language != "DE"
		&& language != "EN"
		&& language != "FR"
		&& language != "ES"
		&& language != "IT"
		&& language != "NL"
		&& language != "PL"
		&& language != "PT-BR"
		&& language != "TR"
		&& language != "RU"
		&& language != "JA"
		&& language != "KO"
		&& language != "ZH-CN"
		&& language != "CS"
		&& language != "SV"
		&& language != "UK"
		&& language != "HU"
		&& language != "RO"
		&& language != "EL"
		&& language != "DA"
		&& language != "FI"
		&& language != "NO"
	)
		return

    CurrentLanguage := language

    IniWrite(
        CurrentLanguage,
        ConfigFile,
        "General",
        "Language"
    )
}

AutoButtonFont(ctrl, text)
{
    visible := RegExReplace(text, "^[^\n]*\n")

    len := StrLen(visible)

    size := 14

    if (len >= 8)
        size := 12
	
	if (len >= 9)
        size := 11
	
    if (len >= 11)
        size := 10

    if (len >= 22)
        size := 9

    ctrl.SetFont("s" size, "Segoe UI")
    ctrl.Text := text
}

AutoControlFont(ctrl, text)
{
    len := StrLen(text)

    size := 14

    if (len >= 18)
        size := 13
	
	if (len >= 19)
        size := 12
	
    if (len >= 21)
        size := 11

    if (len >= 28)
        size := 9

    ctrl.SetFont("s" size, "Segoe UI")
    ctrl.Text := text
}

; ==========================================================
; SETTINGS LADEN / SPEICHERN
; ==========================================================

LoadSettings()
{
    global ConfigFile, Programs, paused
    paused := IniRead(ConfigFile, "General", "Paused", 0) = 1
    if !FileExist(ConfigFile)
        IniWrite(0, ConfigFile, "Programs", "Count")
    count := IniRead(ConfigFile, "Programs", "Count", 0)
    Loop count
    {
        section := "Program" A_Index
        name := IniRead(ConfigFile, section, "Name", "")
        if (name = "")
            continue
        Programs[name] := {
            Path: IniRead(ConfigFile, section, "Path", ""),
            RatioW: Max(1, Integer(IniRead(ConfigFile, section, "RatioW", "16"))),
            RatioH: Max(1, Integer(IniRead(ConfigFile, section, "RatioH", "9"))),
            Position: IniRead(ConfigFile, section, "Position", "TOPLEFT"),
            Area: IniRead(ConfigFile, section, "Area", "WINDOW"),
            OffsetTop: Integer(IniRead(ConfigFile, section, "OffsetTop", 0)),
            OffsetBottom: Integer(IniRead(ConfigFile, section, "OffsetBottom", 0)),
            OffsetLeft: Integer(IniRead(ConfigFile, section, "OffsetLeft", 0)),
            OffsetRight: Integer(IniRead(ConfigFile, section, "OffsetRight", 0)),
			PreferredClass: IniRead(ConfigFile, section, "PreferredClass", ""),
			AnalysisPending: IniRead(ConfigFile, section, "AnalysisPending", 0) = 1,
			AnalysisVersion: Integer(IniRead(ConfigFile, section, "AnalysisVersion", 0))
        }
    }
}


SaveSettings()
{
    global ConfigFile, Programs
    ; Alle alten Sections löschen
    Loop 1000
    {
        try
        {
            IniDelete(ConfigFile, "Program" A_Index)
        }
        catch
        {
        }
    }
    index := 1
    for name, data in Programs
    {
        section := "Program" index
        IniWrite(name, ConfigFile, section, "Name")
        IniWrite(data.Path, ConfigFile, section, "Path")
        IniWrite(data.RatioW, ConfigFile, section, "RatioW")
        IniWrite(data.RatioH, ConfigFile, section, "RatioH")
        IniWrite(data.Position, ConfigFile, section, "Position")
        IniWrite(data.Area, ConfigFile, section, "Area")
        IniWrite(data.OffsetTop, ConfigFile, section, "OffsetTop")
        IniWrite(data.OffsetBottom, ConfigFile, section, "OffsetBottom")
        IniWrite(data.OffsetLeft, ConfigFile, section, "OffsetLeft")
        IniWrite(data.OffsetRight, ConfigFile, section, "OffsetRight")
		IniWrite(data.PreferredClass, ConfigFile, section, "PreferredClass")
		IniWrite(
			HasProp(data, "AnalysisPending") ? data.AnalysisPending : 0,
			ConfigFile,
			section,
			"AnalysisPending"
		)

		IniWrite(
			HasProp(data, "AnalysisVersion") ? data.AnalysisVersion : 0,
			ConfigFile,
			section,
			"AnalysisVersion"
		)
        index++
    }
    IniWrite(Programs.Count, ConfigFile, "Programs", "Count")
}

; ===========================================
; PROGRAMM-EINSTELLUNGEN
; ===========================================

EnsureProgramDefaults(process)
{
    global Programs

    if !Programs.Has(process)
        return

    data := Programs[process]

    defaults := Map(
		"OffsetTop",0,
		"OffsetBottom",0,
		"OffsetLeft",0,
		"OffsetRight",0,
		"PreferredClass",""
	)

    changed := false

    for key, value in defaults
    {
        if !HasProp(data, key)
        {
            data.%key% := value
            changed := true
        }
    }

    if changed
    {
        Programs[process] := data
        SaveSettings()
    }
}

MarkSettingsForSave()
{
    global SettingsNeedSave

    if SettingsNeedSave
        return

    SettingsNeedSave := true

    SetTimer(FlushSettings, -1000)
}

FlushSettings()
{
    global SettingsNeedSave

    if !SettingsNeedSave
        return

    SettingsNeedSave := false
    SaveSettings()
}

RememberPreferredClass(process, className)
{
    global Programs
    global LearnedChildClass
    if (className = "")
        return
    if !Programs.Has(process)
        return
    if !LearnedChildClass.Has(process)
    {
        LearnedChildClass[process] := {
            Class: className,
            Count: 1
        }
        return
    }
    learned := LearnedChildClass[process]
    if (learned.Class != className)
    {
        learned.Class := className
        learned.Count := 1
        LearnedChildClass[process] := learned
        return
    }
    learned.Count++
    LearnedChildClass[process] := learned

    if (learned.Count < 3)
        return
    data := Programs[process]
	; Bereits gelernt? Dann niemals automatisch überschreiben.
	if (HasProp(data, "PreferredClass")
		&& data.PreferredClass != "")
	{
		return
	}
	data.PreferredClass := className
	Programs[process] := data
	MarkSettingsForSave()
	}

RecoverViewport(process)
{
    global Programs
    global LearnedChildClass
    global LearnedOffsets
    global ChildCache

    if !Programs.Has(process)
        return false

    data := Programs[process]

    ; Alles zurücksetzen
    data.PreferredClass := ""

    data.OffsetTop := 0
    data.OffsetBottom := 0
    data.OffsetLeft := 0
    data.OffsetRight := 0

    Programs[process] := data

    ; Gelernte Klassen löschen
    if LearnedChildClass.Has(process)
        LearnedChildClass.Delete(process)

    ; Gelernte Offsets löschen
    if LearnedOffsets.Has(process)
        LearnedOffsets.Delete(process)

    ; Child-Cache komplett leeren
    ChildCache.Clear()

    MarkSettingsForSave()

    return true
}

CalibrateOffsets(process, parentViewport, childViewport)
{
    global Programs
    global LearnedOffsets

    if !Programs.Has(process)
        return

    left := childViewport.X - parentViewport.X
    top := childViewport.Y - parentViewport.Y

    right :=
        (parentViewport.X + parentViewport.Width)
        - (childViewport.X + childViewport.Width)

    bottom :=
        (parentViewport.Y + parentViewport.Height)
        - (childViewport.Y + childViewport.Height)
	; Ungültige Messung verwerfen
	if (
		left < 0
		|| top < 0
		|| right < 0
		|| bottom < 0
	)
		return
	; Unrealistisch große Offsets verwerfen
	if (
		left > 150
		|| top > 150
		|| right > 150
		|| bottom > 150
	)
    return
    if (Abs(left) < 2)
        left := 0

    if (Abs(top) < 2)
        top := 0

    if (Abs(right) < 2)
        right := 0

    if (Abs(bottom) < 2)
        bottom := 0

    signature := left "|" top "|" right "|" bottom

    if !LearnedOffsets.Has(process)
    {
        LearnedOffsets[process] := {
            Signature: signature,
            Count: 1
        }
        return
    }

    learned := LearnedOffsets[process]

    if (learned.Signature != signature)
    {
        learned.Signature := signature
        learned.Count := 1
        LearnedOffsets[process] := learned
        return
    }

    learned.Count++
    LearnedOffsets[process] := learned

    ; Erst nach 3 gleichen Messungen übernehmen
    if (learned.Count < 3)
        return

    data := Programs[process]

    changed := false

    if (data.OffsetLeft != left)
    {
        data.OffsetLeft := left
        changed := true
    }

    if (data.OffsetTop != top)
    {
        data.OffsetTop := top
        changed := true
    }

    if (data.OffsetRight != right)
    {
        data.OffsetRight := right
        changed := true
    }

    if (data.OffsetBottom != bottom)
    {
        data.OffsetBottom := bottom
        changed := true
    }

    if changed
	{
		Programs[process] := data
		; Lernzustand zurücksetzen
		if LearnedOffsets.Has(process)
			LearnedOffsets.Delete(process)
		MarkSettingsForSave()
	}
}

HasCalibrated(process)
{
    global Programs

    if !Programs.Has(process)
        return false

    data := Programs[process]

    return (
        HasProp(data, "OffsetTop")
        && HasProp(data, "OffsetBottom")
        && HasProp(data, "OffsetLeft")
        && HasProp(data, "OffsetRight")
        && (
            data.OffsetTop != 0
            || data.OffsetBottom != 0
            || data.OffsetLeft != 0
            || data.OffsetRight != 0
        )
    )
}

QueueCalibration(process, parentViewport, childViewport)
{
    global PendingCalibration

    PendingCalibration[process] := {
        Parent: parentViewport,
        Child: childViewport
    }

    SetTimer(CalibrationTimer.Bind(process), -250)
}

CalibrationTimer(process)
{
    global PendingCalibration

    if !PendingCalibration.Has(process)
        return

    data := PendingCalibration[process]
    PendingCalibration.Delete(process)

    CalibrateOffsets(
        process,
        data.Parent,
        data.Child
    )
}

; ==========================================================
; FENSTER-PRÜFUNGEN
; ==========================================================

IsMainWindow(hwnd)
{
    ; Fenster existiert noch?
    if !hwnd || !DllCall("IsWindow", "Ptr", hwnd)
        return false
    if !DllCall("IsWindowVisible", "Ptr", hwnd)
        return false
    try
    {
        style := WinGetExStyle("ahk_id " hwnd)
    }
    catch
    {
        return false
    }
    ; WS_EX_TOOLWINDOW
    if (style & 0x80)
        return false
    ; Fenster mit Besitzer sind meistens Dialoge
    try
    {
        owner := DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr")
        if owner
            return false
    }
    catch
    {
        return false
    }
    try
    {
        title := WinGetTitle("ahk_id " hwnd)
    }
    catch
    {
        return false
    }
    return (title != "")
}


IsWindowMaximized(hwnd)
{
    if !DllCall("IsWindow", "Ptr", hwnd)
        return false

    try
        return WinGetMinMax("ahk_id " hwnd) = 1
    catch
        return false
}


; ==========================================================
; STARTUP WINDOWS
; ==========================================================

SimulateResize(hwnd, process)
{
    global startW, startH
    global startWindowW, startWindowH
    global ResizeStart

    if !DllCall("IsWindow", "Ptr", hwnd)
    return false

	if !Programs.Has(process)
    return false

    try
    {
        WinGetPos(
            &x,
            &y,
            &winW,
            &winH,
            "ahk_id " hwnd
        )

        data := Programs[process]

        viewport := ViewportResolver.Resolve(
            hwnd,
            process,
            data
        )

        startWindowW := winW
        startWindowH := winH

        startW := viewport.Width
        startH := viewport.Height

        ResizeStart[hwnd] := {
            WindowX: x,
            WindowY: y,
            WindowW: winW,
            WindowH: winH,
            CenterX: x + Floor(winW / 2),
            CenterY: y + Floor(winH / 2),
            Viewport: viewport
        }
    }
    catch
    {
        return false
    }

    ; entspricht EVENT_SYSTEM_MOVESIZEEND

    FixRatio(hwnd, process)
	return true
}

CheckStartupWindows()
{
    global Programs, CheckedStartupWindows

    for hwnd in WinGetList()
    {
        if !IsMainWindow(hwnd)
            continue

        if CheckedStartupWindows.Has(hwnd)
            continue

        try
            process := WinGetProcessName("ahk_id " hwnd)
        catch
            continue

        if !Programs.Has(process)
            continue

        data := Programs[process]

		if (HasProp(data, "AnalysisPending")
			&& data.AnalysisPending)
		{
			ProgramAnalyzer.Start(process)
		}

		if SimulateResize(hwnd, process)
		{
			CheckedStartupWindows[hwnd] := true
		}
    }
}


FixStartupRatio(hwnd, process)
{
    SimulateResize(hwnd, process)
}

; ==========================================================
; EINSTELLUNGEN GUI
; ==========================================================

SelectWindowArea(*)
{
    global selectedArea

    selectedArea := "WINDOW"
    UpdateAreaButtons()
    MarkSettingsChanged()
}

SelectClientArea(*)
{
    global selectedArea

    selectedArea := "CLIENT"
    UpdateAreaButtons()
    MarkSettingsChanged()
}


UpdateAreaButtons()
{
    global selectedArea
    global areaWindowButton, areaClientButton

    areaWindowButton.Value := (selectedArea = "WINDOW")
    areaClientButton.Value := (selectedArea = "CLIENT")
}

SelectTopLeftPosition(*)
{
    global selectedPosition

    selectedPosition := "TOPLEFT"
    UpdatePositionButtons()
    MarkSettingsChanged()
}

SelectCenterPosition(*)
{
    global selectedPosition

    selectedPosition := "CENTER"
    UpdatePositionButtons()
    MarkSettingsChanged()
}


UpdatePositionButtons()
{
    global selectedPosition
    global positionTopLeftButton, positionCenterButton

    positionTopLeftButton.Value := (selectedPosition = "TOPLEFT")
    positionCenterButton.Value := (selectedPosition = "CENTER")
}

ChangeLanguage(*)
{
    global LanguageDropdown
    global CurrentProgram
    global SettingsDirty
    global OriginalSettings
    global IgnoreControlEvents

    if !IsObject(LanguageDropdown)
        return

    selected := LanguageDropdown.Text

    SetLanguage(selected)

    LangClearCache()

    CreateTrayMenu()

    SettingsDirty := false
    CurrentProgram := ""
    OriginalSettings := Map()
    IgnoreControlEvents := false

    CloseSettings()
    OpenSettings()
}

CreateSettingsWindow()
{
    global SettingsGui

    SettingsGui := Gui("+AlwaysOnTop", Lang("SettingsWindowTitle"))
    SettingsGui.SetFont("s13", "Segoe UI")
    SettingsGui.OnEvent("Close", CloseSettings)
}


CloseSettings(*)
{
    global SettingsGui, SettingsListView, ProgramImageList
    if SettingsGui
    {
        try
            SettingsGui.Destroy()
    }
    SettingsGui := 0
    SettingsListView := 0
    ; ImageList erst nach Gui-Zerstörung freigeben
    if ProgramImageList
    {
        try
            IL_Destroy(ProgramImageList)
        catch
        {
        }
        ProgramImageList := 0
    }
}


OpenSettings(*)
{
    global Programs, SettingsListView, ProgramImageList, SettingsGui
	global CurrentLanguage, LanguageDropdown
    global DefaultIconIndex, ratioWEdit, ratioHEdit
    global areaWindowButton, areaClientButton, selectedArea
    global positionTopLeftButton, positionCenterButton, selectedPosition
    global ListRowToProgram
    if SettingsGui
    {
        try
        {
            SettingsGui.Show()
            WinActivate("ahk_id " SettingsGui.Hwnd)
            return
        }
        catch
        {
            SettingsGui := 0
        }
    }
    CreateSettingsWindow()
    settingsGui := SettingsGui
    ; ===== LINKE SPALTE =====
    title := settingsGui.AddText("x15 y15", Lang("Programs"))
    title.SetFont("s12 bold", "Segoe UI")
    ; ===== RECHTE SPALTE =====
    title := settingsGui.AddText("x340 y15", Lang("Settings"))
    title.SetFont("s12 bold", "Segoe UI")
    ; ImageList für Icons
    if ProgramImageList
    {
        try
            IL_Destroy(ProgramImageList)
        catch
        {
        }
    }
    ProgramImageList := IL_Create(32, 32, true)
    DefaultIconIndex := IL_Add(ProgramImageList, A_WinDir "\System32\shell32.dll", 1)
    SettingsListView := settingsGui.AddListView(
		"x15 y40 w310 h400 -Hdr -Multi +VScroll",
		["Programm"]
	)
	SettingsListView.OnEvent("Click", (*) => ForceListViewScrollbar())
	OnMessage(0x203, KeepListViewSelection) ; WM_LBUTTONDBLCLK
	OnMessage(0x201, KeepListViewSelection) ; WM_LBUTTONDOWN
	OnMessage(0x200, ListViewMouseMove) ; WM_MOUSEMOVE
    SettingsListView.SetImageList(ProgramImageList)
    SendMessage(0x1000 + 3, 1, ProgramImageList, SettingsListView.Hwnd)  ; LVM_SETIMAGELIST
    SettingsListView.SetFont("s12", "Segoe UI")
    SettingsListView.ModifyCol(1, 290)
    ; Liste füllen
    ListRowToProgram.Clear()
    for name, data in Programs
    {
        icon := GetProgramIcon(data)
        iconIndex := (icon) ? IL_Add(ProgramImageList, icon, 1) : DefaultIconIndex
        row := SettingsListView.Add("Icon" iconIndex, DisplayProgramName(name))
        ListRowToProgram[row] := name
    }
    ; ===== EINSTELLUNGSFELDER =====
    title := settingsGui.AddText("x340 y65", Lang("AspectRatio"))
    title.SetFont("s10 bold", "Segoe UI")
    ratioWEdit := settingsGui.AddEdit("x340 y90 w60", "16")
	ratioWEdit.OnEvent("Change", MarkSettingsChanged)
    ratioColon := settingsGui.AddText("x405 y90", ":")
    ratioColon.SetFont("s16 bold", "Segoe UI")
    ratioHEdit := settingsGui.AddEdit("x420 y90 w60", "9")
	ratioHEdit.OnEvent("Change", MarkSettingsChanged)
    title := settingsGui.AddText("x340 y145", Lang("Position"))
    title.SetFont("s10 bold", "Segoe UI")
	positionTopLeftButton := settingsGui.AddRadio(
		"x340 y167 w85 h55 +0x1000 Group",
		""
	)

	AutoButtonFont(positionTopLeftButton, "◰`n" Lang("TopLeft"))

	positionCenterButton := settingsGui.AddRadio(
		"x435 y167 w85 h55 +0x1000",
		""
	)

	AutoButtonFont(positionCenterButton, "⊙`n" Lang("Center"))
    positionTopLeftButton.OnEvent("Click", SelectTopLeftPosition)
	positionCenterButton.OnEvent("Click", SelectCenterPosition)
    title := settingsGui.AddText("x340 y225", Lang("Area"))
    title.SetFont("s10 bold", "Segoe UI")
	areaWindowButton := settingsGui.AddRadio(
		"x340 y244 w85 h55 +0x1000 Group",
		""
	)

	AutoButtonFont(areaWindowButton, "🖼`n" Lang("Window"))

	areaClientButton := settingsGui.AddRadio(
		"x435 y244 w85 h55 +0x1000",
		""
	)

	AutoButtonFont(areaClientButton, "🎬`n" Lang("Content"))
    areaWindowButton.OnEvent("Click", SelectWindowArea)
	areaClientButton.OnEvent("Click", SelectClientArea)
    ; ===== BUTTONS =====
    global SaveButton, RemoveButton
	SaveButton := settingsGui.AddButton(
		"x340 y310 w180 h30",
		""
	)
	AutoControlFont(SaveButton, Lang("Save"))
	RemoveButton := settingsGui.AddButton(
		"x340 y350 w180 h30",
		""
	)
	AutoControlFont(RemoveButton, Lang("RemoveProgram"))
	addButton := settingsGui.AddButton(
		"x340 y390 w180 h30",
		""
	)
	AutoControlFont(addButton, Lang("AddProgram"))
    settingsGui.AddText("x340 y430 w180 h2 0x10")  ; Trennlinie
	; ===== SPRACHAUSWAHL =====

	LanguageDropdown := settingsGui.AddDropDownList(
		"x15 y445 w80",
		[
			"DE",
			"EN",
			"FR",
			"ES",
			"IT",
			"NL",
			"PL",
			"PT-BR",
			"TR",
			"RU",
			"JA",
			"KO",
			"ZH-CN",
			"CS",
			"SV",
			"UK",
			"HU",
			"RO",
			"EL",
			"DA",
			"FI",
			"NO"
		]
	)

	languages := [
		"DE",
		"EN",
		"FR",
		"ES",
		"IT",
		"NL",
		"PL",
		"PT-BR",
		"TR",
		"RU",
		"JA",
		"KO",
		"ZH-CN",
		"CS",
		"SV",
		"UK",
		"HU",
		"RO",
		"EL",
		"DA",
		"FI",
		"NO"
	]

	for index, languageCode in languages
	{
		if (languageCode = CurrentLanguage)
		{
			LanguageDropdown.Value := index
			break
		}
	}

	LanguageDropdown.OnEvent(
		"Change",
		ChangeLanguage
	)
    closeButton := settingsGui.AddButton(
		"x340 y440 w180 h30",
		""
	)
	AutoControlFont(closeButton, Lang("Close"))
		; ===== EVENTS =====
    SettingsListView.OnEvent("ItemSelect", LoadSelected)
	SettingsListView.OnEvent("ItemFocus", (*) => ForceListViewScrollbar())
	SaveButton.OnEvent("Click", SaveSelected)
	RemoveButton.OnEvent("Click", RemoveSelected)
	addButton.OnEvent("Click", AddCurrentWindow)
	closeButton.OnEvent("Click", CloseSettings)
    ; Erstes Element auswählen
    if (Programs.Count > 0)
    {
        SettingsListView.Modify(1, "Select Focus")
        SetTimer(LoadSelected, -10)
    }
    
	
	UpdateRemoveButton()
	hasPrograms := (Programs.Count > 0)
	positionTopLeftButton.Enabled := hasPrograms
	positionCenterButton.Enabled := hasPrograms
	areaWindowButton.Enabled := hasPrograms
	areaClientButton.Enabled := hasPrograms
	UpdateAreaButtons()
	UpdateRatioFields()
	UpdatePositionButtons()

	hasPrograms := (Programs.Count > 0)

	SaveButton.Enabled := false
	RemoveButton.Enabled := hasPrograms

	ratioWEdit.Enabled := hasPrograms
	ratioHEdit.Enabled := hasPrograms

	positionTopLeftButton.Enabled := hasPrograms
	positionCenterButton.Enabled := hasPrograms

	areaWindowButton.Enabled := hasPrograms
	areaClientButton.Enabled := hasPrograms

	if !hasPrograms
	{
		ratioWEdit.Value := "-"
		ratioHEdit.Value := "-"

		selectedPosition := ""
		selectedArea := ""

		positionTopLeftButton.Value := false
		positionCenterButton.Value := false

		areaWindowButton.Value := false
		areaClientButton.Value := false
	}
	
	versionText := settingsGui.AddText("x518 y460 w30 Right c808080", "V.1.0")
	versionText.SetFont("s10", "Segoe UI")
	settingsGui.Show("w560 h480")
	ForceListViewScrollbar()
}


MarkSettingsChanged(*)
{
    global SettingsDirty, SaveButton, IgnoreControlEvents
    global OriginalSettings
    global ratioWEdit, ratioHEdit, selectedPosition, selectedArea

    if IgnoreControlEvents
        return

    if (OriginalSettings.Count = 0)
    {
        SettingsDirty := true
    }
    else
    {
        w := ratioWEdit.Value
		h := ratioHEdit.Value

		if (w = "" || h = "")
		{
			SettingsDirty := true
		}
		else
		{
			SettingsDirty :=
			(
				Integer(w) != OriginalSettings["RatioW"]
				|| Integer(h) != OriginalSettings["RatioH"]
				|| selectedPosition != OriginalSettings["Position"]
				|| selectedArea != OriginalSettings["Area"]
			)
		}
    }

    if IsObject(SaveButton)
        SaveButton.Enabled := SettingsDirty
}

; ==========================================================
; LISTEN-AKTIONEN (auf oberster Ebene, nicht mehr geschachtelt)
; ==========================================================

SaveSelected(*)
{
    global Programs, SettingsListView, ListRowToProgram
	global ratioWEdit, ratioHEdit, selectedPosition, selectedArea
	global OriginalSettings
	global SettingsDirty, CurrentProgram, SaveButton
    row := SettingsListView.GetNext()
	if !row
		return
	selected := ListRowToProgram[row]
	if (!selected || !Programs.Has(selected))
		return
    ; EINGABEVALIDIERUNG
    if (ratioWEdit.Value = "" || ratioHEdit.Value = "")
	{
		MsgBox(
			Lang("MissingRatioValues")
		)
		return
	}

	if (ratioWEdit.Value = "-" || ratioHEdit.Value = "-")
		return

	if !ValidateRatio(&newW, &newH)
		return
		
    Programs[selected].RatioW := newW
    Programs[selected].RatioH := newH
    Programs[selected].Position := selectedPosition
    Programs[selected].Area := selectedArea
    SaveSettings()

	if (selectedArea = "CLIENT")
	{
		hwnd := WinExist("ahk_exe " selected)

		if hwnd
		{
			ProgramAnalyzer.Start(selected)
		}
		else
		{
			Programs[selected].AnalysisPending := true
			SaveSettings()
		}
	}

	CheckedStartupWindows.Clear()
	CheckStartupWindows()
	OriginalSettings := Map(
		"RatioW", newW,
		"RatioH", newH,
		"Position", selectedPosition,
		"Area", selectedArea
	)
	SettingsDirty := false
	CurrentProgram := selected
	if IsObject(SaveButton)
    SaveButton.Enabled := false
    ShowStatus(Format(Lang("ProgramSaved"), DisplayProgramName(selected)))
}

ValidateRatio(&newW, &newH)
{
    global ratioWEdit, ratioHEdit
    global SettingsGui

    if !RegExMatch(ratioWEdit.Value, "^\d+$")
    || !RegExMatch(ratioHEdit.Value, "^\d+$")
    {
        if IsObject(SettingsGui)
        {
            WinActivate("ahk_id " SettingsGui.Hwnd)

            MsgBox(
                Lang("InvalidRatio"),
                Lang("InvalidInputTitle"),
                "Owner" SettingsGui.Hwnd " Icon!"
            )
        }
        else
        {
            MsgBox(
                Lang("InvalidRatio"),
                Lang("InvalidInputTitle"),
                "Icon!"
            )
        }

        return false
    }

    newW := Integer(ratioWEdit.Value)
    newH := Integer(ratioHEdit.Value)

    if (newW <= 0 || newH <= 0)
    {
        if IsObject(SettingsGui)
        {
            WinActivate("ahk_id " SettingsGui.Hwnd)

            MsgBox(
                Lang("InvalidRatio"),
                Lang("InvalidInputTitle"),
                "Owner" SettingsGui.Hwnd " Icon!"
            )
        }
        else
        {
            MsgBox(
                Lang("InvalidRatio"),
                Lang("InvalidInputTitle"),
                "Icon!"
            )
        }

        return false
    }

    return true
}

SaveProgram(program)
{
    global Programs
    global ratioWEdit, ratioHEdit
    global selectedPosition, selectedArea
    global SettingsDirty, CurrentProgram, SaveButton

    if (!program || !Programs.Has(program))
        return

    if !ValidateRatio(&newW, &newH)
		return

	oldArea := Programs[program].Area

	Programs[program].RatioW := newW
	Programs[program].RatioH := newH
	Programs[program].Position := selectedPosition
	Programs[program].Area := selectedArea

	if (selectedArea = "CLIENT"
		&& oldArea != "CLIENT")
	{
		Programs[program].AnalysisPending := true
		Programs[program].AnalysisVersion := 0
	}
    SaveSettings()
	CheckedStartupWindows.Clear()
	CheckStartupWindows()

	SettingsDirty := false
    CurrentProgram := program

    if IsObject(SaveButton)
        SaveButton.Enabled := false

    ShowStatus(Format(Lang("ProgramSaved"), DisplayProgramName(program)))
}

RemoveSelected(*)
{
    global Programs, SettingsListView, ListRowToProgram, RemoveButton
    row := SettingsListView.GetNext()
    if !row
        return
    displayName := SettingsListView.GetText(row, 1)
    if (displayName = "")
        return
    selected := ListRowToProgram[row]
    if (!selected || !Programs.Has(selected))
        return
    ; Aktuelle Position merken
	selectedRow := row
	global SettingsDirty, CurrentProgram

	if (CurrentProgram = selected)
	{
		SettingsDirty := false
		CurrentProgram := ""
	}
	Programs.Delete(selected)
	SaveSettings()
	UpdateRemoveButton()
	; Nächste Zeile auswählen
	if (Programs.Count > 0)
	{
		if (selectedRow > Programs.Count)
        selectedRow := Programs.Count
		RefreshProgramList(selectedRow)
	}
	else
	{
		RefreshProgramList()
	}
	ShowStatus(Format(Lang("ProgramRemoved"), displayName))
}

KeepListViewSelection(wParam, lParam, msg, hwnd)
{
    global SettingsListView

    if !IsObject(SettingsListView)
        return

    if (hwnd != SettingsListView.Hwnd)
        return
	ForceListViewScrollbar()
    ; Prüfen, ob auf eine Zeile geklickt wurde
    Hit := SendMessage(0x1012, 0, 0, hwnd) ; LVM_GETNEXTITEM

    ; Wenn in den leeren Bereich geklickt wurde:
    ; vorhandene Auswahl behalten
    MouseGetPos(, , , &ctrl)

    if (ctrl = "SysListView32")
    {
        row := SettingsListView.GetNext()
        if row
        {
            ; Auswahl wiederherstellen
            SetTimer(() => (
                SettingsListView.Modify(row, "Select Focus")
            ), -10)
        }
    }
}

ListViewMouseMove(wParam, lParam, msg, hwnd)
{
    global SettingsListView

    if !IsObject(SettingsListView)
        return

    if (hwnd != SettingsListView.Hwnd)
        return

    ForceListViewScrollbar()
}

LoadSelected(*)
{
    global IgnoreControlEvents
    Critical
    IgnoreControlEvents := true
    global Programs, SettingsListView, ListRowToProgram
	global CurrentProgram, SettingsDirty
    global ratioWEdit, ratioHEdit, selectedPosition, selectedArea
	global OriginalSettings
    row := SettingsListView.GetNext()
	if !row
	{
		; Auswahl verloren -> letzte Auswahl wiederherstellen
		if (CurrentProgram != "")
		{
			for oldRow, oldName in ListRowToProgram
			{
				if (oldName = CurrentProgram)
				{
					SettingsListView.Modify(oldRow, "Select Focus")
					break
				}
			}
		}
		return
	}
    selected := ListRowToProgram[row]
	if (selected != CurrentProgram && SettingsDirty)
	{
		global SettingsGui

		if IsObject(SettingsGui)
		{
			WinActivate("ahk_id " SettingsGui.Hwnd)
			result := MsgBox(
				Format(Lang("UnsavedText"), DisplayProgramName(CurrentProgram)),
				Lang("UnsavedTitle"),
				"YesNoCancel Owner" SettingsGui.Hwnd " Icon!"
			)
		}
		else
		{
			result := MsgBox(
				Format(Lang("UnsavedText"), DisplayProgramName(CurrentProgram)),
				Lang("UnsavedTitle"),
				"YesNoCancel Icon!"
			)
		}
	if (result = "Cancel")
	{
		oldProgram := CurrentProgram
		IgnoreControlEvents := true

		for oldRow, oldName in ListRowToProgram
		{
			if (oldName = oldProgram)
			{
				SettingsListView.Modify(0, "-Select")
				SettingsListView.Modify(oldRow, "Select Focus")
				break
			}
		}

		SetTimer(() => RestoreSelectedProgram(oldProgram), -200)
		SetTimer(() => (IgnoreControlEvents := false), -250)

		SettingsDirty := true	
		return
	}
	if (result = "Yes")
	{
		SaveProgram(CurrentProgram)
	}
	}
    if (!selected || !Programs.Has(selected))
        return
	ratioWEdit.Enabled := true
	ratioHEdit.Enabled := true
    data := Programs[selected]
	OriginalSettings := Map(
		"RatioW", data.RatioW,
		"RatioH", data.RatioH,
		"Position", data.Position,
		"Area", data.Area
	)
    ratioWEdit.Value := data.RatioW
    ratioHEdit.Value := data.RatioH
    selectedPosition := data.Position
    if (selectedPosition = "")
        selectedPosition := "TOPLEFT"
    UpdatePositionButtons()
    selectedArea := data.Area
        if (data.Area = "WINDOW")
        SelectWindowArea()
    else
        SelectClientArea()

    IgnoreControlEvents := false

    SettingsDirty := false
    CurrentProgram := selected

    if IsObject(SaveButton)
        SaveButton.Enabled := false
	; Auswahl in ListView sichtbar halten
    row := SettingsListView.GetNext()
    if row
    {
        SettingsListView.Modify(0, "-Select")
        SettingsListView.Modify(row, "Select Focus")
    }
}

UpdateRemoveButton()
{
    global RemoveButton, Programs
    global positionTopLeftButton, positionCenterButton
    global areaWindowButton, areaClientButton

    enabled := (Programs.Count > 0)

    if IsObject(RemoveButton)
        RemoveButton.Enabled := enabled

    if IsObject(positionTopLeftButton)
    {
        positionTopLeftButton.Enabled := enabled
        if !enabled
            positionTopLeftButton.Value := false
    }

    if IsObject(positionCenterButton)
    {
        positionCenterButton.Enabled := enabled
        if !enabled
            positionCenterButton.Value := false
    }

    if IsObject(areaWindowButton)
    {
        areaWindowButton.Enabled := enabled
        if !enabled
            areaWindowButton.Value := false
    }

    if IsObject(areaClientButton)
    {
        areaClientButton.Enabled := enabled
        if !enabled
            areaClientButton.Value := false
    }
}

UpdateRatioFields()
{
    global ratioWEdit, ratioHEdit, Programs

    if !IsObject(ratioWEdit) || !IsObject(ratioHEdit)
        return

    enabled := (Programs.Count > 0)

    ratioWEdit.Enabled := enabled
    ratioHEdit.Enabled := enabled

    if enabled
    {
        ratioWEdit.Opt("-Background202020")
        ratioHEdit.Opt("-Background202020")
    }
    else
    {
        ratioWEdit.Opt("+Backgroundf9f9f9")
        ratioHEdit.Opt("+Backgroundf9f9f9")
    }
}

ForceListViewScrollbar()
{
    global SettingsListView

    if !IsObject(SettingsListView)
        return

    if !WinExist("ahk_id " SettingsListView.Hwnd)
        return

    ; Vertikale Scrollbar dauerhaft einblenden
    DllCall("ShowScrollBar"
        , "Ptr", SettingsListView.Hwnd
        , "Int", 1      ; SB_VERT
        , "Int", true)
}

RestoreSelectedProgram(program)
{
    global SettingsListView, ListRowToProgram, CurrentProgram

    if (CurrentProgram != program)
        return

    for row, name in ListRowToProgram
    {
        if (name = program)
        {
            SettingsListView.Modify(0, "-Select")
            SettingsListView.Modify(row, "Select Focus")
            return
        }
    }
}

RefreshProgramList(selectIndex := 1)
{
	UpdateRemoveButton()
    global Programs, SettingsListView, ProgramImageList, DefaultIconIndex
    global ListRowToProgram, RemoveButton
    if !SettingsListView
        return
    SettingsListView.Delete()
    ListRowToProgram.Clear()
    for name, data in Programs
    {
        icon := GetProgramIcon(data)
        iconIndex := (icon) ? IL_Add(ProgramImageList, icon, 1) : DefaultIconIndex
        row := SettingsListView.Add("Icon" iconIndex, DisplayProgramName(name))
        ListRowToProgram[row] := name
    }
        if (Programs.Count > 0)
		{
			if (selectIndex > Programs.Count)
				selectIndex := Programs.Count
			if (selectIndex < 1)
            selectIndex := 1
			SettingsListView.Modify(selectIndex, "Select Focus")
			SetTimer(LoadSelected, -10)
			; Scrollbar erst nach dem Neuaufbau erzwingen
			SetTimer(ForceListViewScrollbar, -30)
		}
    else
	{
	    SetTimer(ForceListViewScrollbar, -30)

		selectedPosition := ""
		selectedArea := ""

		if IsObject(positionTopLeftButton)
			positionTopLeftButton.Value := false

		if IsObject(positionCenterButton)
			positionCenterButton.Value := false

		if IsObject(areaWindowButton)
			areaWindowButton.Value := false

		if IsObject(areaClientButton)
			areaClientButton.Value := false
		
		if IsObject(ratioWEdit)
		{
			ratioWEdit.Value := ""
			ratioWEdit.Enabled := false
		}

		if IsObject(ratioHEdit)
		{
			ratioHEdit.Value := ""
			ratioHEdit.Enabled := false
		}
			UpdateRemoveButton()
			UpdateRatioFields()
	}
}


; ==========================================================
; FENSTER HINZUFÜGEN (NICHT-BLOCKIEREND)
; ==========================================================

AddCurrentWindow(*)
{
    global Programs
    ; Bereits offenes Auswahl-GUI schließen
    if WinExist(Lang("SelectWindowTitle"))
    {
        Gui(Lang("SelectWindowTitle")).Destroy()
    }

    selectGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x40000", Lang("SelectWindowTitle"))
    selectGui.BackColor := "202020"

    text := selectGui.AddText(
        "cFFFFFF w300 h80 Center",
        Format(Lang("SelectWindowCountdown"), 10)
    )
    text.SetFont("s14 bold", "Segoe UI")

    selectGui.Show("NA Center")
    WinSetAlwaysOnTop(true, "ahk_id " selectGui.Hwnd)

    state := {
        selectedHwnd: 0,
        attempts: 0,
        gui: selectGui,
        text: text,
        timerRef: 0,
        clickHandler: 0
    }

    state.timerRef := AddCurrentWindowCallback.Bind(state)

    global SelectingWindow
    SelectingWindow := true

    state.clickHandler := SelectClickedWindow.Bind(state)
    Hotkey("~LButton", state.clickHandler, "On")
    SetTimer(state.timerRef, 1000)
}

AddCurrentWindowCallback(state)
{
    ; Prüfen, ob GUI und Text-Control noch existieren
    if (!IsObject(state.gui) || !IsObject(state.text))
        return
    if !WinExist("ahk_id " state.gui.Hwnd)
        return
    state.attempts++
    ; Nach 10 Sekunden abbrechen
    if (state.attempts >= 10)
	{
		SetTimer(state.timerRef, 0)
		if (state.clickHandler)
			Hotkey("~LButton", state.clickHandler, "Off")
		state.gui.Destroy()
		ShowStatus(Lang("NoWindowSelected"))
		return
	}
    remaining := 10 - state.attempts
	state.text.Text := Format(Lang("SelectWindowCountdown"), remaining)
}

SelectClickedWindow(state, *)
{
    global SelectingWindow, ScriptPID
    MouseGetPos(, , &hwnd)
    if (!hwnd || hwnd = state.gui.Hwnd)
        return
    ; Prüfen ob echtes Fenster
    if !IsMainWindow(hwnd)
        return
    ; Desktop ignorieren
    try
        class := WinGetClass("ahk_id " hwnd)
    catch
        class := ""
    if (class = "Progman" || class = "WorkerW")
        return
    ; Eigenen Prozess ignorieren
    try
        pid := WinGetPID("ahk_id " hwnd)
    catch
        pid := 0
    if (pid = ScriptPID)
        return
    ; Auswahl erfolgreich
    SelectingWindow := false
    if (state.clickHandler)
        Hotkey("~LButton", state.clickHandler, "Off")
    SetTimer(state.timerRef, 0)
    state.selectedHwnd := hwnd
    state.gui.Destroy()
    ProcessSelectedWindow(hwnd)
}

ProcessSelectedWindow(selectedHwnd)
{
    global Programs, RemoveButton, SettingsGui
    try
    {
        process := WinGetProcessName("ahk_id " selectedHwnd)
        processPath := ""
        try
            processPath := WinGetProcessPath("ahk_id " selectedHwnd)
        catch
        {
        }
    }
    catch
	{
		ShowStatus(Lang("ProgramNotDetected"))
		return
	}

	if Programs.Has(process)
	{
		ShowStatus(Format(Lang("ProgramAlreadyAdded"), DisplayProgramName(process)))
		return
	}
    Programs[process] := {
		Path: processPath,
		RatioW: 16,
		RatioH: 9,
		Position: "TOPLEFT",
		Area: "WINDOW",
		OffsetTop: 0,
		OffsetBottom: 0,
		OffsetLeft: 0,
		OffsetRight: 0,
		PreferredClass: "",
		AnalysisPending: false,
		AnalysisVersion: 0
	}
    SaveSettings()
	if IsObject(RemoveButton)
	{
		RemoveButton.Enabled := true
	}
	if IsObject(positionTopLeftButton)
	{
		positionTopLeftButton.Enabled := true
		positionCenterButton.Enabled := true
		areaWindowButton.Enabled := true
		areaClientButton.Enabled := true
	}
	; Neues Programm in der Liste auswählen
	newIndex := 1
	for name in Programs
	{
		if (name = process)
			break
		newIndex++
	}

RefreshProgramList(newIndex)
UpdateRatioFields()

CheckedStartupWindows.Clear()
CheckStartupWindows()

ShowStatus(Format(Lang("ProgramAdded"), DisplayProgramName(process)))

}

; ==========================================================
; EVENT HOOK
; ==========================================================

callback := CallbackCreate(WinEvent, "F")

hookStart := DllCall(
    "SetWinEventHook",
    "UInt", EVENT_SYSTEM_MOVESIZESTART,
    "UInt", EVENT_SYSTEM_MOVESIZESTART,
    "Ptr", 0,
    "Ptr", callback,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0
)

hookEnd := DllCall(
    "SetWinEventHook",
    "UInt", EVENT_SYSTEM_MOVESIZEEND,
    "UInt", EVENT_SYSTEM_MOVESIZEEND,
    "Ptr", 0,
    "Ptr", callback,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0
)

hookShow := DllCall(
    "SetWinEventHook",
    "UInt", EVENT_OBJECT_SHOW,
    "UInt", EVENT_OBJECT_SHOW,
    "Ptr", 0,
    "Ptr", callback,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0
)

OnExit(Cleanup)


; ==========================================================
; WINDOW EVENT
; ==========================================================

WinEvent(hWinEventHook, event, hwnd, idObject, idChild, idEventThread, msEventTime)
{
    global startW, startH, startWindowW, startWindowH
    global paused, correcting, resizing
    global ResizeStart
    global ProcessCache
    global Programs

    ; ==========================================================
    ; NEUES FENSTER / PROGRAMM STARTET
    ; ==========================================================

    if (event = EVENT_OBJECT_CREATE
        || event = EVENT_OBJECT_SHOW)
    {
        if hwnd
        {
            SetTimer(CheckStartupWindows, -300)
        }

        return
    }


    ; ==========================================================
    ; NORMALE OBJEKT-EVENTS IGNORIEREN
    ; (nicht bei SHOW/CREATE anwenden)
    ; ==========================================================

    if (idObject != 0)
        return


    if !hwnd
        return


    if !IsMainWindow(hwnd)
        return


    ; ==========================================================
    ; AB HIER NUR NOCH RESIZE-HANDLING
    ; ==========================================================

    if correcting || paused || analyzing
		return


    ; ==========================================================
    ; PROCESS ERMITTELN
    ; ==========================================================

    process := ""

    if (ProcessCache.Has(hwnd))
    {
        process := ProcessCache[hwnd]
    }
    else
    {
        try
            process := WinGetProcessName("ahk_id " hwnd)
        catch
            return

        CacheManager.Set(ProcessCache, hwnd, process)
    }


    if !Programs.Has(process)
        return



    ; ==========================================================
    ; RESIZE START
    ; ==========================================================

    if (event = EVENT_SYSTEM_MOVESIZESTART)
    {
        resizing := true

        startW := 0
        startH := 0

        try
        {
            WinGetPos(
                ,
                ,
                &startWindowW,
                &startWindowH,
                "ahk_id " hwnd
            )

            data := Programs[process]

            viewport := ViewportResolver.Resolve(
                hwnd,
                process,
                data
            )

            startW := viewport.Width
            startH := viewport.Height


            WinGetPos(
                &startX,
                &startY,
                &startWinW,
                &startWinH,
                "ahk_id " hwnd
            )


            ResizeStart[hwnd] := {
                WindowX: startX,
                WindowY: startY,
                WindowW: startWinW,
                WindowH: startWinH,
                CenterX: startX + Floor(startWinW / 2),
                CenterY: startY + Floor(startWinH / 2),
                Viewport: viewport
            }
        }
        catch
        {
            return
        }

        return
    }


    ; ==========================================================
    ; RESIZE ENDE
    ; ==========================================================

    if (event = EVENT_SYSTEM_MOVESIZEEND)
    {
        resizing := false

        try
        {
            WinGetPos(
                ,
                ,
                &endWindowW,
                &endWindowH,
                "ahk_id " hwnd
            )

            if (endWindowW = startWindowW
                && endWindowH = startWindowH)
            {
                return
            }

            FixRatio(hwnd, process)
        }
        catch
        {
            return
        }

        return
    }
}


; ==========================================================
; GRÖSSENBERECHNUNGEN
; ==========================================================

GetClientSize(hwnd, &cw, &ch)
{
    rect := Buffer(16)
    if !DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
        return false
    cw := NumGet(rect, 8, "Int")
    ch := NumGet(rect, 12, "Int")
    return true
}

GetClientRectEx(hwnd, &x, &y, &w, &h)
{
    rect := Buffer(16)

    if !DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
        return false

    w := NumGet(rect, 8, "Int")
    h := NumGet(rect, 12, "Int")

    pt := Buffer(8)

    NumPut("Int", 0, pt, 0)
    NumPut("Int", 0, pt, 4)

    if !DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt)
        return false

    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")

    return true
}

GetWindowSizeFromClient(hwnd, clientW, clientH, &winW, &winH)
{
    style := WinGetStyle("ahk_id " hwnd)
    exStyle := WinGetExStyle("ahk_id " hwnd)
    rect := Buffer(16)
    NumPut("Int", 0, rect, 0)
    NumPut("Int", 0, rect, 4)
    NumPut("Int", clientW, rect, 8)
    NumPut("Int", clientH, rect, 12)
    dpi := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
    ; Fallback für ältere Windows-Versionen
    if (!dpi || !DllCall("AdjustWindowRectExForDpi", "Ptr", rect, "UInt", style, "Int", false, "UInt", exStyle, "UInt", dpi))
    {
        if !DllCall("AdjustWindowRectEx", "Ptr", rect, "UInt", style, "Int", false, "UInt", exStyle)
            return false
    }
    winW := NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int")
    winH := NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int")
    return true
}


; ==========================================================
; KORREKTUR-FUNKTIONEN
; ==========================================================

CorrectWindowAfterResize(hwnd, RatioW, RatioH, targetW, targetH, centerX := 0, centerY := 0)
{
    try
	{
		WinGetPos(&x, &y, &realW, &realH, "ahk_id " hwnd)
	}
    catch
    {
        return
    }

    ; Alles bereits korrekt
    if (realW = targetW && realH = targetH)
        return

    ; Windows hat vermutlich eine Mindestgröße erzwungen.
    ; Jetzt immer von der tatsächlich übernommenen Größe ausgehen.

    if (Abs(realW - targetW) > Abs(realH - targetH))
        realH := Round(realW * RatioH / RatioW)
    else
        realW := Round(realH * RatioW / RatioH)
	; Nur neu zentrieren, wenn Windows die gewünschte Größe übernommen hat.
	; Bei erzwungener Mindestgröße aktuelle Position beibehalten.
	; Nur zentrieren, wenn Windows die gewünschte Größe übernommen hat
	if ((realW = targetW && realH = targetH)
		&& (centerX || centerY))
	{
		x := Round(centerX - Floor(realW / 2))
		y := Round(centerY - Floor(realH / 2))

		WinMove(x, y, realW, realH, "ahk_id " hwnd)
		return
	}

	; Mindestgröße wurde erzwungen:
	; Position unverändert lassen
	WinMove(x, y, realW, realH, "ahk_id " hwnd)
}

FixClientRatio(parentHwnd, childHwnd, RatioW, RatioH, PositionMode, keepPosition := false)
{
    global startW, startH
    try
    {
        WinGetPos(&px, &py, &pw, &ph, "ahk_id " parentHwnd)
        WinGetPos(, , &cw, &ch, "ahk_id " childHwnd)
    }
    catch
    {
        return
    }
    ; Basis: aktuelle Child-Größe
    newChildW := cw
    newChildH := ch
    ; Welche Dimension wurde geändert?
    deltaW := Abs(cw - startW)
    deltaH := Abs(ch - startH)
    if (deltaW > deltaH)
        newChildH := Round(cw * RatioH / RatioW)
    else
        newChildW := Round(ch * RatioW / RatioH)
    ; Fenster-Ränder berechnen
    borderW := pw - cw
    borderH := ph - ch
    newWindowW := newChildW + borderW
    newWindowH := newChildH + borderH
    ; Mittelpunkt nur merken.
	; Die endgültige Position wird nach der Größenänderung berechnet.
	centerX := 0
	centerY := 0
	if (PositionMode = "CENTER" && !keepPosition)
	{
		centerX := px + Floor(pw / 2)
		centerY := py + Floor(ph / 2)
	}
	if (PositionMode = "CENTER" && !keepPosition)
	{
		px := Round(centerX - Floor(newWindowW / 2))
		py := Round(centerY - Floor(newWindowH / 2))
	}
    ; Unnötige Updates vermeiden
    if (Abs(newWindowW - pw) <= 3 && Abs(newWindowH - ph) <= 3)
        return
    if IsWindowMaximized(parentHwnd)
        return
    global correcting := true
    WinMove(px, py, newWindowW, newWindowH, "ahk_id " parentHwnd)
	WinGetPos(&realX, &realY, &realWindowW, &realWindowH, "ahk_id " parentHwnd)
	; Hat Windows die Mindestgröße erzwungen?
	if (realWindowW != newWindowW || realWindowH != newWindowH)
	{
		if GetClientSize(childHwnd, &realClientW, &realClientH)
		{
			borderW := realWindowW - realClientW
			borderH := realWindowH - realClientH
			if (Abs(realWindowW - newWindowW) > Abs(realWindowH - newWindowH))
				realClientH := Round(realClientW * RatioH / RatioW)
			else
				realClientW := Round(realClientH * RatioW / RatioH)
			WinMove(
				realX,
				realY,
				realClientW + borderW,
				realClientH + borderH,
				"ahk_id " parentHwnd
			)
			; Danach noch einmal die tatsächlich übernommene Größe auslesen
			; und erneut exakt auf den Mittelpunkt setzen.
		}
	}
    {
        correcting := false
    }
    SetTimer(() => VerifyRatio(parentHwnd, WinGetProcessName("ahk_id " parentHwnd), true), -150)
}

CorrectClientRatio(hwnd, process, targetWindowW, targetWindowH, centerX, centerY)
{
	global correcting
	global Programs
	Sleep(30)
	try
	{
		WinGetPos(&realX, &realY, &realW, &realH, "ahk_id " hwnd)
	}
	catch
	{
		return
	}
	; centerX und centerY stammen vom Resize-Beginn.
	if (realW = targetWindowW && realH = targetWindowH)
		return
	if !Programs.Has(process)
		return
	data := Programs[process]
	targetRatio := data.RatioW / data.RatioH
	; Tatsächliche Clientgröße ermitteln
	if !GetClientSize(hwnd, &clientW, &clientH)
		return
	newClientW := clientW
	newClientH := clientH
	; Welche Dimension wurde von Windows begrenzt?
	if (Abs(realW - targetWindowW) > Abs(realH - targetWindowH))
	{
		; Mindestbreite erreicht → Höhe anpassen
		newClientH := Round(clientW / targetRatio)
	}
	else
	{
		; Mindesthöhe erreicht → Breite anpassen
		newClientW := Round(clientH * targetRatio)
	}
	; Benötigte Fenstergröße aus Clientgröße berechnen
	if !GetWindowSizeFromClient(hwnd, newClientW, newClientH, &newW, &newH)
		return
	correcting := true

	try
	{
		; Windows übernimmt evtl. andere Größe
		WinMove(realX, realY, newW, newH, "ahk_id " hwnd)

		; Tatsächlich übernommene Größe lesen
		WinGetPos(&realX, &realY, &realW, &realH, "ahk_id " hwnd)

		; Nur im CENTER-Modus neu zentrieren
		; Nur zentrieren, wenn die gewünschte Größe erreicht wurde
		if ((realW = targetWindowW && realH = targetWindowH)
			&& (centerX || centerY))
		{
			realX := Round(centerX - Floor(realW / 2))
			realY := Round(centerY - Floor(realH / 2))
	
			WinMove(realX, realY,,, "ahk_id " hwnd)
		}
	}
	finally
	{
		correcting := false
	}
}

; ==========================================================
; HAUPT-KORREKTUR
; ==========================================================

FixRatio(hwnd, process, keepPosition := false)
{
    global Programs, startW, startH, startWindowW, startWindowH
	global ResizeStart
	global correcting, paused, resizing
	wasMaximized := false
    if paused || resizing
        return
	    if !DllCall("IsWindow", "Ptr", hwnd)
        return
	if (!Programs.Has(process) || correcting)
		return
	EnsureProgramDefaults(process)
	data := Programs[process]
	if !IsObject(data)
    return
    if (startWindowW = 0 || startWindowH = 0)
        WinGetPos(, , &startWindowW, &startWindowH, "ahk_id " hwnd)
    RatioW := Max(1, data.RatioW)
    RatioH := Max(1, data.RatioH)
    PositionMode := data.Position
    AreaMode := data.Area
	viewport := ViewportResolver.Resolve(hwnd, process, data)
	child := (viewport.Source = "CHILD") ? viewport.Hwnd : 0
	wasMaximized := IsWindowMaximized(hwnd)
    try
    {
        WinGetPos(&oldX, &oldY, &w, &h, "ahk_id " hwnd)
    }
    catch
    {
        return
    }
    x := oldX
    y := oldY
    ; Start-Client-Größe ermitteln
    if (startW = 0 || startH = 0)
	{
		startW := viewport.Width
		startH := viewport.Height
		if (startW <= 0 || startH <= 0)
			return
	}
    ; ==================================================
    ; WINDOW MODE
    ; ==================================================
    if (AreaMode = "WINDOW")
    {
        newW := w
        newH := h
        deltaW := Abs(w - startWindowW)
        deltaH := Abs(h - startWindowH)
        ; Fallback falls Resize-Start nicht erkannt wurde
        if (startWindowW = 0 || startWindowH = 0)
        {
            if (w / h > RatioW / RatioH)
            {
                deltaW := 10
                deltaH := 0
            }
            else
            {
                deltaW := 0
                deltaH := 10
            }
        }
        if (deltaW > deltaH)
            newH := Round(w * RatioH / RatioW)
        else
            newW := Round(h * RatioW / RatioH)
        ; Mittelpunkt des aktuellen Fensters merken.
		; Die endgültige Position wird erst nach der Größenänderung berechnet.
		centerX := 0
		centerY := 0
		if (PositionMode = "CENTER")
		{
			centerX := oldX + Floor(w / 2)
			centerY := oldY + Floor(h / 2)
		}

		; Beim ersten WinMove Position NICHT ändern
		x := oldX
		y := oldY
        ; Unnötige Updates vermeiden
        if (Abs(newW - w) <= 1 && Abs(newH - h) <= 1)
            return
        try
		{
			WinMove(x, y, newW, newH, "ahk_id " hwnd)
			; Hat Windows eine andere Größe übernommen?
			WinGetPos(&realX, &realY, &realW, &realH, "ahk_id " hwnd)
			; Nur zentrieren, wenn Windows die gewünschte Größe übernommen hat
			if (PositionMode = "CENTER"
				&& realW = newW
				&& realH = newH)
			{
				realX := Round(centerX - Floor(realW / 2))
				realY := Round(centerY - Floor(realH / 2))

				WinMove(realX, realY,,, "ahk_id " hwnd)
			}
			CorrectWindowAfterResize(
				hwnd,
				RatioW,
				RatioH,
				newW,
				newH,
				centerX,
				centerY
			)
			SetTimer(() => VerifyRatio(hwnd, process, true), -150)
		}
		catch
		{
		}
        return
    }
        ; ==================================================
		; CLIENT MODE
		; ==================================================
		clientW := viewport.Width
		clientH := viewport.Height
		if (clientW <= 0 || clientH <= 0)
			return
		if (AreaMode = "CLIENT" && child)
		{
			FixClientRatio(hwnd, child, RatioW, RatioH, PositionMode, keepPosition)
			return
		}
		; Client-Modus ohne Child oder gleiches Fenster
		newClientW := clientW
		newClientH := clientH
		deltaClientW := Abs(clientW - startW)
		deltaClientH := Abs(clientH - startH)
		; Fallback wie im WINDOW-Modus
		if (startW = 0 || startH = 0)
		{
			if (clientW / clientH > RatioW / RatioH)
			{
				deltaClientW := 10
				deltaClientH := 0
			}
			else
			{
				deltaClientW := 0
				deltaClientH := 10
			}
		}
		if (deltaClientW > deltaClientH)
			newClientH := Round(clientW * RatioH / RatioW)
		else
			newClientW := Round(clientH * RatioW / RatioH)
		; Fenstergröße aus Client-Größe berechnen
		if !GetWindowSizeFromClient(hwnd, newClientW, newClientH, &newW, &newH)
			return
		; Mittelpunkt merken
		centerX := 0
		centerY := 0
		if (PositionMode = "CENTER")
		{
			centerX := oldX + Floor(w / 2)
			centerY := oldY + Floor(h / 2)
		}

		; Beim ersten WinMove Position NICHT ändern
		x := oldX
		y := oldY
		if (Abs(newW - w) <= 1 && Abs(newH - h) <= 1)
			return
		correcting := true
	try
	{
		; Erste Größenänderung
		WinMove(x, y, newW, newH, "ahk_id " hwnd)
		if wasMaximized
			WinMaximize("ahk_id " hwnd)
	}
	catch
	{
	}
	finally
	{
		correcting := false
	}
		; Tatsächlich übernommene Größe prüfen
		WinGetPos(&realX, &realY, &realW, &realH, "ahk_id " hwnd)
		
		; Nur zentrieren, wenn Windows die gewünschte Größe übernommen hat
		if (PositionMode = "CENTER"
			&& realW = newW
			&& realH = newH)
		{
			realX := Round(centerX - Floor(realW / 2))
			realY := Round(centerY - Floor(realH / 2))

			WinMove(realX, realY,,, "ahk_id " hwnd)
		}
		
		; Nur nachkorrigieren, wenn Windows die gewünschte Größe
		; NICHT übernommen hat (z.B. Mindestgröße erreicht)
		if (realW != newW || realH != newH)
		{
			SetTimer(
				() => CorrectClientRatio(
					hwnd,
					process,
					newW,
					newH,
					0,
					0
				),
				-30
			)
		}

		SetTimer(() => VerifyRatio(hwnd, process, true), -150)

		; zweite Prüfung nach Windows-Mindestgrößenkorrektur
		SetTimer(() => RecheckClientRatio(hwnd, process), -300)
		}


; ==========================================================
; VERIFIZIERUNG
; ==========================================================

VerifyRatio(hwnd, process, refresh := false)
{
    global Programs, correcting, verifying, RATIO_TOLERANCE
    global resizing
	if verifying || correcting || resizing
		return
    verifying := true
    try
    {
        if !Programs.Has(process)
            return
        if (refresh)
        {
            Sleep(30)
            try
                WinGetPos(, , &dummyW, &dummyH, "ahk_id " hwnd)
            catch
                return
        }
        data := Programs[process]
        viewport := ViewportResolver.Resolve(hwnd, process, data)
        w := viewport.Width
		h := viewport.Height
		if (w <= 0 || h <= 0)
			return
        currentRatio := w / h
        targetRatio := data.RatioW / data.RatioH
        difference := Abs(currentRatio - targetRatio)
        if (difference > RATIO_TOLERANCE)
		{
			if (data.Area = "CLIENT")
			{
				ViewportResolver.HandleClientFailure(
					hwnd,
					process
				)
				return
			}
			FixRatio(hwnd, process)
		}
		else
		{
			ViewportResolver.ResetClientFailures(process)
		}
    }
    finally
    {
        verifying := false
    }
}

RecheckClientRatio(hwnd, process)
{
    global Programs

    if !Programs.Has(process)
        return

    data := Programs[process]

    if (data.Area != "CLIENT")
        return

    try
    {
        viewport := ViewportResolver.Resolve(hwnd, process, data)
    }
    catch
    {
        return
    }

    if (viewport.Width <= 0 || viewport.Height <= 0)
        return

    currentRatio := viewport.Width / viewport.Height
    targetRatio := data.RatioW / data.RatioH

    if (Abs(currentRatio - targetRatio) > RATIO_TOLERANCE)
    {
        ; alte Startwerte ignorieren
        global startW, startH
        startW := viewport.Width
        startH := viewport.Height

        FixRatio(hwnd, process, true)
    }
}

; ==========================================================
; TRAY FUNKTIONEN
; ==========================================================

TrayClick(wParam, lParam, msg, hwnd)
{
    if (lParam = 0x0203)  ; Doppelklick
        OpenSettings()
}


TogglePause(*)
{
    global paused, ConfigFile, IconFile, PauseIconFile
    global StartupWindows, CheckedStartupWindows

    paused := !paused

    if paused
    {
        StartupWindows.Clear()
        CheckedStartupWindows.Clear()
    }
    else
	{
		StartupWindows.Clear()
		CheckedStartupWindows.Clear()

		SetTimer(CheckStartupWindows, 100)
	}

    IniWrite(paused ? 1 : 0, ConfigFile, "General", "Paused")

    if (paused && FileExist(PauseIconFile))
        TraySetIcon(PauseIconFile)
    else if FileExist(IconFile)
        TraySetIcon(IconFile)

    if paused
    {
        try
            A_TrayMenu.Rename("Ratio-Lock pausieren", "Ratio-Lock fortsetzen")
        catch
        {
        }
    }
    else
    {
        try
            A_TrayMenu.Rename("Ratio-Lock fortsetzen", "Ratio-Lock pausieren")
        catch
        {
        }
    }
}


EnableStartup(*)
{
    taskName := "WindowRatioLock"
    scriptPath := A_ScriptFullPath
    cmd := 'schtasks /Create '
        . '/TN "' taskName '" '
        . '/TR "\"' scriptPath '\"" '
        . '/SC ONLOGON '
        . '/RL HIGHEST '
        . '/F'
    result := RunWait(A_ComSpec " /c " cmd, , "Hide")
    if (result != 0)
	{
		ShowStatus(Lang("AutostartFailed"))
		return
	}

	ShowStatus(Lang("AutostartEnabled"))
    Sleep(1500)
    Reload()
}

StartupEnabled()
{
    taskName := "WindowRatioLock"
    cmd := 'schtasks /Query /TN "' taskName '"'
    result := RunWait(A_ComSpec " /c " cmd, , "Hide")
    return result = 0
}

DisableStartup(*)
{
    taskName := "WindowRatioLock"
    cmd := 'schtasks /Delete /TN "' taskName '" /F'

    RunWait(A_ComSpec " /c " cmd, , "Hide")

    ShowStatus(Lang("AutostartDisabled"))
    Sleep(1500)
    Reload()
}

ExitScript(*)
{
    ExitApp()
}


; ==========================================================
; CLEANUP
; ==========================================================

Cleanup(*)
{
    global hookStart, hookEnd, callback
    global StatusGui, SettingsGui, ProgramImageList
    global CheckedStartupWindows
        try
        ProcessCache.Clear()
    catch
    {
    }

    try
        ChildCache.Clear()
    catch
    {
    }

    try
        CheckedStartupWindows.Clear()
    catch
    {
    }
    if hookStart
        DllCall("UnhookWinEvent", "Ptr", hookStart)
    if hookEnd
        DllCall("UnhookWinEvent", "Ptr", hookEnd)
    if callback
        CallbackFree(callback)
    if IsObject(StatusGui)
        try
            StatusGui.Destroy()
    catch
    {
    }
    if IsObject(SettingsGui)
        try
            SettingsGui.Destroy()
    catch
    {
    }
    if ProgramImageList
    {
        try
            IL_Destroy(ProgramImageList)
        catch
        {
        }
    }
}