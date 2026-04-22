import Vapor
import Foundation

struct SummarizerService {
    private let ollamaURL = Environment.get("OLLAMA_URL") ?? "http://127.0.0.1:11434/api/generate"
    
    func generateSummary(for text: String, client: Client, language: String) async throws -> String {
        guard text.count > 50 else { return "Текст слишком короткий для конспекта." }

        let prompt: String
        switch language {
        case "en":
            prompt = """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>
            YOU ARE A PROFESSIONAL ACADEMIC ASSISTANT AND LINGUISTIC ANALYZER.
            Your task is to create the MOST DETAILED, structured, and comprehensive set of notes.

            STRICT FORMATTING RULES:
            1. OUTPUT ONLY THE TEXT OF THE NOTES. No introductions.
            2. USE CAPS LOCK FOR HEADINGS AND IMPORTANT SECTIONS.
            3. Use regular dashes (-) for bulleted lists.
            4. Do not provide a brief summary. Write out the text in maximum detail, dividing it into logical blocks.
            <|eot_id|><|start_header_id|>user<|end_header_id|>
            Lecture text for analysis:
            \(text)
            
            [CRITICAL REMINDER: YOU MUST OUTPUT THE ENTIRE RESPONSE STRICTLY IN ENGLISH. DO NOT USE ANY OTHER LANGUAGE.]<|eot_id|>
            <|start_header_id|>assistant<|end_header_id|>
            """
        case "ro":
            prompt = """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>
            EȘTI UN ASISTENT ACADEMIC PROFESIONIST ȘI UN ANALIZATOR LINGVISTIC.
            Sarcina ta este să creezi un conspect CÂT MAI DETALIAT, structurat și voluminos.

            REGULI STRICTE DE FORMATARE:
            1. AFIȘEAZĂ DOAR TEXTUL CONSPECTULUI. Fără introduceri.
            2. PENTRU TITLURI ȘI SECȚIUNI IMPORTANTE, FOLOSEȘTE CAPS LOCK.
            3. Folosește liniuțe obișnuite (-) pentru listele cu puncte.
            4. Nu face o scurtă rezumată. Redactează textul cât mai detaliat posibil.
            <|eot_id|><|start_header_id|>user<|end_header_id|>
            Textul prelegerii pentru analiză:
            \(text)
            
            [MEMENTO CRITIC: TREBUIE SĂ GENEREZI ÎNTREGUL RĂSPUNS STRICT ÎN LIMBA ROMÂNĂ. TRADUCE TOTUL. NU FOLOSI ENGLEZA!]<|eot_id|>
            <|start_header_id|>assistant<|end_header_id|>
            """
        case "fr":
            prompt = """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>
            TU ES UN ASSISTANT ACADÉMIQUE PROFESSIONNEL ET UN ANALYSEUR LINGUISTIQUE.
            Ta tâche est de créer un compte-rendu LE PLUS DÉTAILLÉ, structuré et volumineux possible.

            RÈGLES DE MISE EN FORME STRICTES :
            1. AFFICHE UNIQUEMENT LE TEXTE DU COMPTE-RENDU. Pas d'introduction.
            2. POUR LES TITRES ET LES SECTIONS IMPORTANTES, UTILISE LE CAPS LOCK.
            3. Utilise des tirets simples (-) pour les listes à puces.
            4. Ne fais pas de résumé succinct. Rédige le texte de la manière la plus détaillée possible.
            <|eot_id|><|start_header_id|>user<|end_header_id|>
            Texte de la conférence pour analyse :
            \(text)
            
            [RAPPEL CRITIQUE: TU DOIS GÉNÉRER TOUTE LA RÉPONSE STRICTEMENT EN FRANÇAIS. TRADUIS TOUT. N'UTILISE PAS L'ANGLAIS!]<|eot_id|>
            <|start_header_id|>assistant<|end_header_id|>
            """
        default: // "ru"
            prompt = """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>
            ТЫ — ПРОФЕССИОНАЛЬНЫЙ АКАДЕМИЧЕСКИЙ АССИСТЕНТ И ЛИНГВИСТИЧЕСКИЙ АНАЛИЗАТОР.
            Твоя задача — создать МАКСИМАЛЬНО ПОДРОБНЫЙ, структурированный и объемный конспект.

            СТРОГИЕ ПРАВИЛА ОФОРМЛЕНИЯ:
            1. ВЫВОДИ ТОЛЬКО ТЕКСТ КОНСПЕКТА. Никаких вступлений ("Вот ваш конспект").
            2. ДЛЯ ЗАГОЛОВКОВ И ВАЖНЫХ РАЗДЕЛОВ ИСПОЛЬЗУЙ CAPS LOCK.
            3. Используй обычные тире (-) для маркированных списков.
            4. Не делай краткую выжимку. Распиши текст максимально подробно, разделяя на логические блоки и подтемы.
            <|eot_id|><|start_header_id|>user<|end_header_id|>
            Текст лекции для анализа:
            \(text)
            
            [КРИТИЧЕСКИ ВАЖНО: ТЫ ОБЯЗАН СГЕНЕРИРОВАТЬ ВЕСЬ КОНСПЕКТ СТРОГО НА РУССКОМ ЯЗЫКЕ. ПЕРЕВЕДИ ВСЁ. НЕ ИСПОЛЬЗУЙ АНГЛИЙСКИЙ!]<|eot_id|>
            <|start_header_id|>assistant<|end_header_id|>
            """
        }
        
        let ollamaRequest = OllamaRequest(
            model: "llama3.1:8b-instruct-q8_0", prompt: prompt, stream: false,
            options: OllamaOptions(num_predict: 8192, temperature: 0.3, repeat_penalty: 1.1)
        )

        let response = try await client.post(URI(string: ollamaURL)) { req in
            try req.content.encode(ollamaRequest)
        }
        let result = try response.content.decode(OllamaResponse.self)
        var cleanedResponse = result.response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if isModelRefusal(cleanedResponse) {
            throw NSError(domain: "ModelRefusal", code: 400, userInfo: [NSLocalizedDescriptionKey: "Модель отказалась"])
        }
        
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "*", with: "")
        
        let prefixes = ["here is", "вот ", "iată ", "voici "]
        for prefix in prefixes {
            if cleanedResponse.lowercased().hasPrefix(prefix) {
                if let firstNewline = cleanedResponse.firstIndex(of: "\n") {
                    cleanedResponse = String(cleanedResponse[firstNewline...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                }
                break
            }
        }
        return cleanedResponse
    }

    private func isModelRefusal(_ response: String) -> Bool {
        let lowercased = response.lowercased()
        let refusalPatterns = [
            "не могу создавать", "не могу помочь", "нарушает политику",
            "against my safety", "i cannot assist", "i cannot provide",
            "nu pot crea", "nu pot ajuta", "je ne peux pas", "en tant que modèle"
        ]
        return refusalPatterns.contains { lowercased.contains($0) }
    }
}
